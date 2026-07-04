#!/usr/bin/env bash
#
# SessionStart auto-tune: the harness observes -> recommends -> applies.
#
# v1.48-pre. `/ulw-report`'s Headline heuristics have long computed a
# directional signal ("Objective-contract block reprompt-rate 63% ...
# Raise objective_contract_min_files ... if it over-fires on your
# prompts") and then stopped — the user still has to read the report,
# decide, and hand-edit oh-my-claude.conf. This hook closes that one
# case end to end, opt-in: when `auto_tune=on`, it reuses show-report.sh's
# EXACT objective-contract reprompt-rate signal and thresholds (see
# "Evidence rule" below) to decide whether the gate looks like it is
# over-firing, and if the evidence is strong enough, nudges
# `objective_contract_min_files` up by one step itself.
#
# This is the harness's first self-modifying case, so it is
# deliberately narrow and conservative:
#   - ONE tuning case (objective_contract_min_files). Not a generic
#     tuning engine.
#   - Mechanical evidence only — no LLM judgment call, no reasoning
#     about whether the user "really" wants this; the rule is a fixed
#     arithmetic threshold over gate_events.jsonl, identical to what
#     show-report.sh already surfaces as a suggestion.
#   - A materially higher confidence bar than the suggestion it is
#     based on: show-report.sh mentions the signal at >=3 blocks and
#     calls it "calibrated correctly" at >=5; this hook requires >=10
#     qualifying blocks in the SAME 7-day window it re-checks on
#     (chosen to match both show-report.sh's own default `week` mode
#     and this hook's own cadence — a narrower, more conservative
#     window than `month`/`all`, so a thin recent sample can't drive a
#     conf write; a determined heavy /ulw user who is genuinely
#     hitting this gate will clear 10 in a week, a light user simply
#     stays a no-op, which is the right failure direction for a
#     mechanism that writes global config).
#   - At most one step per run, clamped to [2,12], and only when the
#     CURRENT value is already inside that managed range — a value of
#     0 (the documented "disable the volume arm" sentinel) or anything
#     above 12 is treated as an explicit user choice this hook does
#     not override.
#   - At most once per 7 days regardless of outcome (state file), so
#     the evidence read + potential conf write only ever happens once
#     a week, not once a session.
#   - Reuses the EXISTING atomic conf-write path
#     (`omc-config.sh set user <k=v>` -> `write_conf_atomic`) instead
#     of a second hand-rolled tmp+mv — same validation, same
#     byte-for-byte preservation of every other conf line.
#
# Evidence rule (mirrors show-report.sh; grep it for `objective_contract`
# to see the source of truth this hook must stay in lockstep with):
#   oc_blocks     = gate_events.jsonl rows where gate=="objective-contract"
#                   and event=="block", ts within the last 7 days
#   oc_reprompts  = same window, event=="post-block-reprompt"
#   oc_pct        = oc_reprompts * 100 / oc_blocks (clamped to 100 when
#                   reprompts > blocks, i.e. the cross-window pairing
#                   case show-report.sh also clamps)
#   Requires oc_blocks >= 10. When oc_pct >= 50 (show-report.sh's own
#   "over-firing" bar), raise objective_contract_min_files by 1 step.
#   Anything else is a no-op (insufficient signal, or the rate is
#   below the over-firing bar) — show-report.sh's calibrated-correct
#   branch says "no action needed", not "consider lowering", so this
#   hook has no lower-the-threshold case; inventing one would not be
#   reusing existing logic/thresholds, it would be a new rule.
#
# SECURITY: `auto_tune` is deny-listed at project-conf scope (see
# common.sh `_parse_conf_file`) — a hostile repo flipping it on via its
# own `.claude/oh-my-claude.conf` could otherwise rewrite the user's
# GLOBAL `~/.claude/oh-my-claude.conf` gate thresholds the moment the
# user `cd`s in, an even larger blast radius than the other deny-listed
# flags (this one is not scoped to the repo at all — it reaches into
# every future project). Only user-level conf or `OMC_AUTO_TUNE=on`
# can enable it.
#
# Disable via `auto_tune=off` (default) in the conf or
# `OMC_AUTO_TUNE=off` env.
#
# Idempotency: per-session `auto_tune_checked` state key AND the
# cross-session 7-day state file both guard re-evaluation — the
# per-session flag additionally covers the same-instant matcher
# fan-out (resume / compact / catchall firing together for one logical
# session start) that the cross-session file's timestamp alone might
# not catch if two hook processes read it before either writes back.

set -euo pipefail


# shellcheck source=../../skills/autowork/scripts/common.sh
. "${HOME}/.claude/skills/autowork/scripts/common.sh"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
[[ -z "${SESSION_ID}" ]] && exit 0

# Opt-in; off by default. is_auto_tune_enabled reads the load_conf-
# populated OMC_AUTO_TUNE (deny-listed at project scope — see common.sh
# _parse_conf_file).
is_auto_tune_enabled || exit 0

# Per-session guard FIRST, before any real work — the check below reads
# and parses gate_events.jsonl and can mutate the user's conf, unlike
# the cheap version-compare in session-start-whats-new.sh, so this
# guards the whole evaluation, not just a message emission.
ensure_session_dir
existing_checked="$(read_state "auto_tune_checked" 2>/dev/null || true)"
if [[ "${existing_checked}" == "1" ]]; then
  exit 0
fi
write_state "auto_tune_checked" "1"

QP_ROOT="${HOME}/.claude/quality-pack"
STATE_FILE="${QP_ROOT}/auto-tune-state.json"
AUDIT_LEDGER="${QP_ROOT}/auto-tune.jsonl"
GATE_EVENTS_FILE="${QP_ROOT}/gate_events.jsonl"
mkdir -p "${QP_ROOT}" 2>/dev/null || true

now_ts="$(now_epoch)"
seven_days=$((7 * 86400))

last_check_ts=0
if [[ -f "${STATE_FILE}" ]]; then
  last_check_ts="$(jq -r '.last_check_ts // 0' "${STATE_FILE}" 2>/dev/null || echo 0)"
  [[ "${last_check_ts}" =~ ^[0-9]+$ ]] || last_check_ts=0
fi

if (( last_check_ts != 0 )) && (( now_ts - last_check_ts < seven_days )); then
  exit 0
fi

# --- Evidence rule ---------------------------------------------------
cutoff_ts=$(( now_ts - seven_days ))
oc_blocks=0
oc_reprompts=0
reason=""
applied=0

if [[ ! -s "${GATE_EVENTS_FILE}" ]]; then
  reason="no gate_events.jsonl ledger yet — nothing to evaluate"
else
  window_rows="$(jq -c --argjson cutoff "${cutoff_ts}" \
    'select((.ts // 0 | tonumber) >= $cutoff)' "${GATE_EVENTS_FILE}" 2>/dev/null || true)"
  oc_blocks="$(printf '%s\n' "${window_rows}" \
    | jq -c 'select(.gate == "objective-contract" and .event == "block")' 2>/dev/null \
    | wc -l | tr -d '[:space:]')"
  oc_reprompts="$(printf '%s\n' "${window_rows}" \
    | jq -c 'select(.gate == "objective-contract" and .event == "post-block-reprompt")' 2>/dev/null \
    | wc -l | tr -d '[:space:]')"
  [[ "${oc_blocks}" =~ ^[0-9]+$ ]] || oc_blocks=0
  [[ "${oc_reprompts}" =~ ^[0-9]+$ ]] || oc_reprompts=0
fi

if (( oc_blocks < 10 )); then
  reason="insufficient signal (${oc_blocks} objective-contract block(s) in the last 7 days, need >=10)"
else
  if (( oc_reprompts > oc_blocks )); then
    oc_pct=100
  else
    oc_pct=$(( oc_reprompts * 100 / oc_blocks ))
  fi

  if (( oc_pct < 50 )); then
    reason="calibrated (${oc_reprompts}/${oc_blocks} = ${oc_pct}% reprompt-rate over the last 7 days — below the 50% over-firing bar; no change)"
  else
    user_conf="${HOME}/.claude/oh-my-claude.conf"
    current="$(grep -E '^objective_contract_min_files=' "${user_conf}" 2>/dev/null \
      | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
    [[ "${current}" =~ ^[0-9]+$ ]] || current=4

    if (( current < 2 || current > 12 )); then
      reason="objective_contract_min_files=${current} is outside auto-tune's managed range [2,12] (0 is the documented volume-arm-disable sentinel; anything above 12 is an explicit override) — leaving it untouched despite a ${oc_pct}% reprompt-rate signal"
    else
      new_value=$(( current + 1 ))
      (( new_value > 12 )) && new_value=12
      if (( new_value == current )); then
        reason="objective_contract_min_files already at the auto-tune ceiling (${current}) — a ${oc_pct}% reprompt-rate signal was present but no further raise is available this cycle"
      else
        omc_config_sh="${HOME}/.claude/skills/autowork/scripts/omc-config.sh"
        # -f, not -x: invoked via `bash <path>`, so only readability
        # matters — omc-config.sh does not carry the executable bit in
        # the source tree (install.sh does not chmod it either), and an
        # -x gate would spuriously refuse a perfectly runnable script.
        if [[ -f "${omc_config_sh}" ]] \
          && bash "${omc_config_sh}" set user "objective_contract_min_files=${new_value}" >/dev/null 2>&1; then
          applied=1
          reason="reprompt-rate ${oc_pct}% over ${oc_blocks} objective-contract blocks (>=50% over-firing bar, >=10-block signal floor, 7-day window) — raised objective_contract_min_files ${current} -> ${new_value}"
          audit_row="$(jq -nc \
            --argjson ts "${now_ts}" \
            --arg flag "objective_contract_min_files" \
            --argjson old "${current}" \
            --argjson new "${new_value}" \
            --arg evidence "reprompt_rate_pct=${oc_pct} blocks=${oc_blocks} reprompts=${oc_reprompts} window_days=7" \
            --arg host "$(omc_host)" \
            '{ts:$ts, flag:$flag, old:$old, new:$new, evidence:$evidence, host:$host}')"
          _do_append_audit_row() {
            printf '%s\n' "${audit_row}" >> "${AUDIT_LEDGER}"
          }
          with_cross_session_log_lock "${AUDIT_LEDGER}" _do_append_audit_row || true
        else
          reason="reprompt-rate ${oc_pct}% over ${oc_blocks} blocks cleared the over-firing bar, but the conf write via omc-config.sh failed — no change applied"
        fi
      fi
    fi
  fi
fi

# Cross-session cadence stamp. Written regardless of outcome — the
# EVALUATION itself (reading + parsing gate_events.jsonl) is throttled
# to once every 7 days, not just the conf write, so a light workload
# that never clears the signal floor doesn't re-read the ledger every
# session either.
_state_tmp="$(mktemp "${STATE_FILE}.XXXXXX" 2>/dev/null || true)"
if [[ -n "${_state_tmp}" ]]; then
  if jq -nc --argjson ts "${now_ts}" --arg reason "${reason}" --argjson applied "${applied}" \
    '{last_check_ts: $ts, last_reason: $reason, last_applied: ($applied == 1)}' \
    > "${_state_tmp}" 2>/dev/null; then
    mv "${_state_tmp}" "${STATE_FILE}" 2>/dev/null || log_anomaly "session-start-auto-tune" "failed to write ${STATE_FILE}"
  else
    rm -f "${_state_tmp}" 2>/dev/null || true
    log_anomaly "session-start-auto-tune" "failed to compose ${STATE_FILE}"
  fi
fi

record_gate_event "auto-tune" "checked" \
  "applied=${applied}" \
  "oc_blocks=${oc_blocks}" \
  "oc_reprompts=${oc_reprompts}"

log_hook "session-start-auto-tune" "auto-tune check: ${reason}"

if (( applied == 1 )); then
  msg="**Auto-tune applied.** Raised \`objective_contract_min_files\` ${current} -> ${new_value} — the last 7 days show a ${oc_pct}% reprompt-rate over ${oc_blocks} objective-contract re-anchor blocks (>=50% over-firing bar, >=10-block signal floor), matching the pattern \`/ulw-report\` already surfaces as a suggestion. Revert with \`objective_contract_min_files=${current}\` in \`~/.claude/oh-my-claude.conf\`, or turn the mechanism off entirely with \`auto_tune=off\`."
  payload="$(jq -nc --arg context "${msg}" '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: $context
    }
  }' 2>/dev/null || true)"
  if [[ -n "${payload}" ]]; then
    printf '%s\n' "${payload}" || log_anomaly "session-start-auto-tune" "failed to emit payload to stdout"
  else
    log_anomaly "session-start-auto-tune" "failed to compose payload"
  fi
fi
