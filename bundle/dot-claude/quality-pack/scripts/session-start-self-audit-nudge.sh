#!/usr/bin/env bash
#
# SessionStart self-audit staleness nudge.
#
# v1.48-pre. CONTRIBUTING.md "Quarterly self-audit cadence" documents
# `/council --self-audit` as a recurring practice — but nothing in the
# harness enforces or even reminds anyone to run it. Left purely to
# memory, a quarterly cadence silently becomes "whenever someone
# happens to remember", which for a harness that audits everyone
# else's projects is the exact self-exemption failure the Bug B
# post-mortem named. This hook is the reminder, modeled on the
# session-start-whats-new.sh / session-start-drift-check.sh pattern:
# read one small cross-session marker file, compare against now,
# emit a one-shot additionalContext nudge when stale.
#
# How it works:
#   1. Read ~/.claude/quality-pack/last-self-audit.json
#      (shape: {"ts": <epoch-of-last-audit>,
#               "last_self_audit_nudge_ts": <epoch-of-last-nudge>}).
#      Missing file, or a missing/zero "ts", means "never audited".
#   2. If the last audit is >90 days old (or never) AND the nudge
#      itself hasn't fired in the last 7 days, emit ONE short
#      additionalContext line suggesting `/council --self-audit`, and
#      stamp last_self_audit_nudge_ts. Silent otherwise.
#   3. `/council --self-audit` is a markdown-driven agentic protocol
#      with no backing script, so there is no natural "on completion"
#      hook to wire a write into. The nudge text instead names
#      `record-self-audit.sh` as the manual completion stamp.
#
# Disable via `self_audit_nudge=off` in the conf or
# `OMC_SELF_AUDIT_NUDGE=off` env. Standard load_conf precedence.
#
# Idempotency: per-session `self_audit_nudge_emitted` state key
# prevents re-emission across SessionStart matchers (resume / compact
# / catchall all fire for one logical session start). Cross-session:
# the last-self-audit.json nudge timestamp dedupes the 7-day re-nudge
# window; the audit timestamp itself dedupes the 90-day staleness
# check.
#
# Failure modes (all soft-exit clean — never block session start):
# - conf flag off → exit silently
# - jq missing or file malformed → treated as "never audited" (fires),
#   matching the fail-safe-toward-reminding posture of a nudge (as
#   opposed to auto-tune's fail-safe-toward-doing-nothing posture,
#   which is right for a mechanism that mutates the user's conf)
# - cross-session state dir not writable → nudge still emits, but the
#   nudge-timestamp write is skipped so the next session retries

set -euo pipefail


# shellcheck source=../../skills/autowork/scripts/common.sh
. "${HOME}/.claude/skills/autowork/scripts/common.sh"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
[[ -z "${SESSION_ID}" ]] && exit 0

# Honor the disable flag. load_conf already populated env vars, so
# OMC_SELF_AUDIT_NUDGE is the source-of-truth value.
if [[ "${OMC_SELF_AUDIT_NUDGE:-on}" == "off" ]]; then
  exit 0
fi

# Bail early if this hook already emitted for this session — the
# matcher fan-out (resume / compact / catchall) can otherwise produce
# three staleness notices on a single SessionStart. Mirrors
# session-start-whats-new.sh / session-start-drift-check.sh exactly:
# this guard is a MESSAGE guard (skip re-emitting), not a CHECK guard
# — the underlying check (compare two epochs in a small JSON file) is
# cheap and side-effect-free, so re-running it on a later matcher
# within the same session is harmless if the message hasn't fired yet.
ensure_session_dir
existing_emitted="$(read_state "self_audit_nudge_emitted" 2>/dev/null || true)"
if [[ "${existing_emitted}" == "1" ]]; then
  exit 0
fi

AUDIT_FILE="${HOME}/.claude/quality-pack/last-self-audit.json"
audit_ts=0
nudge_ts=0
if [[ -f "${AUDIT_FILE}" ]]; then
  audit_ts="$(jq -r '.ts // 0' "${AUDIT_FILE}" 2>/dev/null || echo 0)"
  nudge_ts="$(jq -r '.last_self_audit_nudge_ts // 0' "${AUDIT_FILE}" 2>/dev/null || echo 0)"
  [[ "${audit_ts}" =~ ^[0-9]+$ ]] || audit_ts=0
  [[ "${nudge_ts}" =~ ^[0-9]+$ ]] || nudge_ts=0
fi

now_ts="$(now_epoch)"
staleness_secs=$((90 * 86400))
renudge_secs=$((7 * 86400))

# Never-audited (audit_ts=0) counts as stale by construction.
if (( audit_ts != 0 )) && (( now_ts - audit_ts <= staleness_secs )); then
  exit 0
fi

# Nudged within the last 7 days — stay quiet even though the audit is
# still stale, so the reminder doesn't repeat every session.
if (( nudge_ts != 0 )) && (( now_ts - nudge_ts <= renudge_secs )); then
  exit 0
fi

if (( audit_ts == 0 )); then
  self_audit_msg='**Self-audit never run.** CONTRIBUTING.md documents a quarterly `/council --self-audit` cadence — run it when convenient, then `bash ~/.claude/quality-pack/scripts/record-self-audit.sh` to record completion (no script backs the audit itself, so this stamps the "last run" clock the nudge checks).'
else
  stale_days=$(( (now_ts - audit_ts) / 86400 ))
  self_audit_msg="$(printf '**Self-audit is stale (%sd since last run).** CONTRIBUTING.md'\''s quarterly `/council --self-audit` cadence is overdue — run it when convenient, then `bash ~/.claude/quality-pack/scripts/record-self-audit.sh` to record completion.' "${stale_days}")"
fi

payload="$(jq -nc --arg context "${self_audit_msg}" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $context
  }
}' 2>/dev/null || true)"

if [[ -z "${payload}" ]]; then
  log_anomaly "session-start-self-audit-nudge" "failed to compose payload"
  exit 0
fi

# Emit BEFORE stamping the dedupe state so a failed printf leaves both
# the per-session flag and the cross-session nudge timestamp unchanged
# and retries next session — same pattern as session-start-whats-new.sh.
if ! printf '%s\n' "${payload}"; then
  log_anomaly "session-start-self-audit-nudge" "failed to emit payload to stdout"
  exit 0
fi

write_state "self_audit_nudge_emitted" "1"

# Cross-session nudge-timestamp write. Preserves the audit `ts` field
# verbatim (absent stays absent) so this hook never fabricates a
# completion it did not observe. Soft-fail: if the write fails
# (read-only filesystem, permission), the next SessionStart re-fires
# the notice — acceptable degraded behavior, same rationale as
# session-start-whats-new.sh's cross-session stamp.
STAMP_DIR="$(dirname "${AUDIT_FILE}")"
mkdir -p "${STAMP_DIR}" 2>/dev/null || true
_stamp_tmp="$(mktemp "${AUDIT_FILE}.XXXXXX" 2>/dev/null || true)"
if [[ -n "${_stamp_tmp}" ]]; then
  if [[ -f "${AUDIT_FILE}" ]]; then
    jq --argjson nts "${now_ts}" '.last_self_audit_nudge_ts = $nts' "${AUDIT_FILE}" > "${_stamp_tmp}" 2>/dev/null || true
  else
    jq -nc --argjson nts "${now_ts}" '{last_self_audit_nudge_ts: $nts}' > "${_stamp_tmp}" 2>/dev/null || true
  fi
  if [[ -s "${_stamp_tmp}" ]]; then
    mv "${_stamp_tmp}" "${AUDIT_FILE}" 2>/dev/null || log_anomaly "session-start-self-audit-nudge" "failed to write ${AUDIT_FILE}"
  else
    rm -f "${_stamp_tmp}" 2>/dev/null || true
    log_anomaly "session-start-self-audit-nudge" "failed to compose ${AUDIT_FILE}"
  fi
fi

# Emit a gate event so /ulw-report can count self-audit staleness nudges.
record_gate_event "self-audit-nudge" "nudge-emitted" "audit_ts=${audit_ts}"

log_hook "session-start-self-audit-nudge" "nudge emitted (audit_ts=${audit_ts} now=${now_ts})"
