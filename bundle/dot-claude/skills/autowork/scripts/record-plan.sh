#!/usr/bin/env bash

set -euo pipefail

# v1.27.0 (F-020 / F-021): plan-recording hook does state I/O only — no
# classifier or timing-lib dependency.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${SCRIPT_DIR}/common.sh"

SESSION_ID="$(json_get '.session_id')"
AGENT_TYPE="$(json_get '.agent_type')"
LAST_ASSISTANT_MESSAGE="$(json_get '.last_assistant_message')"

if [[ -z "${SESSION_ID}" || -z "${LAST_ASSISTANT_MESSAGE}" ]]; then
  exit 0
fi

ensure_session_dir

plan_file="$(session_file "current_plan.md")"
# v1.34.1+ (security-lens Z-004): strip C0/C1 control bytes at the
# WRITE site, not only at re-render boundaries. The Wave 3 protected
# router fences and show-report renders, but current_plan.md is the
# durable artifact; any future tool/skill that reads + renders this
# file (debug viewer, ulw-status detail mode, council planner that
# reloads) would re-deliver attacker bytes from a malicious planner
# output. Defense-in-depth: bytes never touch disk = bytes can never
# resurface. _omc_strip_render_unsafe is the canonical helper.
{
  printf '# Plan from %s\n\n' "${AGENT_TYPE:-planner}"
  printf '%s\n' "${LAST_ASSISTANT_MESSAGE}" | _omc_strip_render_unsafe
} >"${plan_file}"

# Parse the v1.14 universal VERDICT contract for planner-class agents
# (prometheus, quality-planner). The reviewer-class parser in
# record-reviewer.sh does not run here, so the verdict is read inline.
# Default to PLAN_READY when no VERDICT line is present so legacy plans
# keep their prior has_plan=true semantics.
plan_verdict="$(printf '%s\n' "${LAST_ASSISTANT_MESSAGE}" \
  | grep -E '^VERDICT:[[:space:]]*(PLAN_READY|NEEDS_CLARIFICATION|BLOCKED)\b' 2>/dev/null \
  | tail -n 1 \
  | sed -E 's/^VERDICT:[[:space:]]*//' \
  | awk '{print $1}' \
  || true)"
plan_verdict="${plan_verdict:-PLAN_READY}"

# --- Plan-complexity computation (v1.19.0) ---
#
# Centralized in a function so the bias-defense layer (stop-guard's
# metis-on-plan gate) and the soft notice below share one source of
# truth. Four orthogonal complexity legs:
#   1. step_count   — numbered list items in the plan body
#   2. file_count   — unique file references with known source extensions
#   3. wave_count   — `Wave N/M:` headers (council Phase 8 wave plans)
#   4. risky_kw     — migration / refactor / schema / breaking / cross-cutting
#
# `plan_complexity_high` is set to "1" when ANY of:
#   - step_count > 5
#   - file_count > 3
#   - wave_count >= 2
#   - risky_kw present AND (step_count >= 4 OR file_count >= 3)
# The keyword-AND-scope condition is conservative: a one-line "refactor
# the comment" plan should not trip the gate just because the word
# 'refactor' appears.
#
# `plan_complexity_signals` is a comma-separated string capturing the
# leg values for scorecard rendering, e.g.
# "steps=7,files=4,waves=2,keywords=migration".
#
# Side-effect-only function (no command-substitution capture) so the
# leg counts and the high/low result both propagate to the caller. Sets
# the following globals:
#   _plan_step_count, _plan_file_count, _plan_wave_count, _plan_keywords
#   _plan_complexity_high  ("1" when high, "" when low)
#   _plan_complexity_signals  (CSV: steps=N,files=N,waves=N[,keywords=...])
_compute_plan_complexity() {
  local message="$1"

  # Use `grep | wc -l` rather than `grep -c || echo 0` because grep -c
  # outputs a number AND exits 1 on no matches, making the `|| echo 0`
  # fallback emit a second "0" that breaks downstream arithmetic. Wrap
  # each grep in `|| true` because `set -o pipefail` is in effect — a
  # no-match grep would otherwise abort the pipeline before wc runs.
  _plan_step_count=$( { grep -E '^\s*[0-9]+\.' <<<"${message}" 2>/dev/null || true; } | wc -l | tr -d '[:space:]')
  _plan_step_count="${_plan_step_count:-0}"
  _plan_file_count=$( { grep -oE '[a-zA-Z0-9_/.-]+\.(ts|tsx|js|jsx|py|sh|md|json|swift|go|rs|rb|java|css|html|yaml|yml|toml|c|cpp|h)' <<<"${message}" 2>/dev/null || true; } | sort -u | wc -l | tr -d '[:space:]')
  _plan_file_count="${_plan_file_count:-0}"
  _plan_wave_count=$( { grep -E '\bWave [0-9]+/[0-9]+\b' <<<"${message}" 2>/dev/null || true; } | wc -l | tr -d '[:space:]')
  _plan_wave_count="${_plan_wave_count:-0}"

  # Risky keyword detection — case-insensitive, word-boundary anchored.
  # Captured into a short label list rather than a count to keep the
  # scorecard readable.
  _plan_keywords=""
  local kw
  for kw in migration refactor schema breaking cross-cutting; do
    if grep -Eiq "\b${kw}\b" <<<"${message}"; then
      _plan_keywords="${_plan_keywords:+${_plan_keywords}|}${kw}"
    fi
  done

  local high=0
  if (( _plan_step_count > 5 )); then high=1; fi
  if (( _plan_file_count > 3 )); then high=1; fi
  if (( _plan_wave_count >= 2 )); then high=1; fi
  if [[ -n "${_plan_keywords}" ]] \
      && { (( _plan_step_count >= 4 )) || (( _plan_file_count >= 3 )); }; then
    high=1
  fi

  if (( high == 1 )); then
    _plan_complexity_high="1"
  else
    _plan_complexity_high=""
  fi

  _plan_complexity_signals="steps=${_plan_step_count},files=${_plan_file_count},waves=${_plan_wave_count}"
  if [[ -n "${_plan_keywords}" ]]; then
    _plan_complexity_signals="${_plan_complexity_signals},keywords=${_plan_keywords}"
  fi
}

_compute_plan_complexity "${LAST_ASSISTANT_MESSAGE}"

# Soft-nudge handoff to PostToolUse:
#
# When the plan is high-complexity, set `plan_complexity_nudge_pending="1"`
# so the PostToolUse Agent hook (`reflect-after-agent.sh`) can surface
# the notice as `additionalContext` — the documented context-injection
# mechanism for that event. SubagentStop does NOT support
# `additionalContext` (silently dropped by Claude Code), so emitting
# from this hook directly does not reach the model. See CLAUDE.md
# "Stop hook output schema" rule.
#
# `reflect-after-agent.sh` clears the flag after emitting (one-shot
# semantics per high-complexity plan).
nudge_flag=""
if [[ "${_plan_complexity_high}" == "1" ]]; then
  nudge_flag="1"
fi

with_state_lock_batch \
  "has_plan" "true" \
  "plan_verdict" "${plan_verdict}" \
  "plan_agent" "${AGENT_TYPE:-planner}" \
  "plan_ts" "$(now_epoch)" \
  "plan_complexity_high" "${_plan_complexity_high}" \
  "plan_complexity_signals" "${_plan_complexity_signals}" \
  "plan_complexity_nudge_pending" "${nudge_flag}" \
  "metis_gate_blocks" ""
