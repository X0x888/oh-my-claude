#!/usr/bin/env bash
#
# circuit-breaker.sh — PostToolUse:Bash hook (v1.44-pre Port 1).
#
# Mechanically enforces the `core.md:128` failure-recovery rule: "3 failed
# attempts at the same target — stop. Revert to known-good. Document tries.
# Switch approach or delegate to oracle." Prior to this hook the rule was
# model-judgment only; the model could (and did) loop on the same failing
# command with argument variations, burning wall-time and tokens.
#
# Mechanism — tracks consecutive same-target Bash failures in per-session
# state. On the third failure with the same target hash, emits an
# `additionalContext` directive instructing the model to revert and
# delegate to oracle, then resets the counter and sets a 60-second
# quiet window so the model has space to act on the directive instead
# of immediately re-tripping the gate.
#
# Target hash: SHA1(tool_name + first_positional_arg + cwd) [first 12 hex].
# Same target with different positional args = different target hashes
# (each tracked independently). The hash collapses argv-variations of
# the SAME command (e.g., `npm test --verbose` and `npm test` both
# hash to npm+cwd) when the first arg is identical; this is what
# core.md:128's "even with argument variations" means in practice.
#
# Edge cases handled:
#   - Background invocations (tool_input.run_in_background==true) are
#     SKIPPED — their tool_response shape reflects spawn success, not
#     underlying command outcome (metis F-7).
#   - Failure detection delegates to common.sh `omc_hook_tool_failed`
#     which canonicalizes across exit_code / status / success field
#     shapes (metis F-2) — sharing the detector with record-verification.sh
#     and record-delivery-action.sh prevents drift.
#   - 60s quiet window after fire (`circuit_quiet_until`) suppresses
#     re-fires while the model is mid-revert (metis F-6).
#   - Counter capped at 10 internally to defend against integer overflow
#     on weird hook replays.
#   - First positional arg missing → fall back to tool_name + cwd hash
#     (rare; defensive).
#
# Conf flag: circuit_breaker=on|off (default on; off in minimal preset).
# Env: OMC_CIRCUIT_BREAKER.

set -euo pipefail

# Fast-path: skip if ULW was never activated in this environment.
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

# v1.27.0 lazy-load gates: this hook does not need classifier or timing
# libs — opt out of eager source for both to keep the PostToolUse hot
# path lean.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"
# v1.47 (sre-lens R-1): observable fail-open — a silent abort here means the
# repeated-failure breaker does not fire for this turn.
omc_arm_failopen_err_trap "circuit-breaker" "(repeated-failure breaker did not evaluate this turn)"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
[[ -z "${SESSION_ID}" ]] && exit 0

# Honor conf flag — `circuit_breaker=off` short-circuits before any state
# I/O so the hook is cost-free when disabled.
if [[ "${OMC_CIRCUIT_BREAKER:-on}" != "on" ]]; then
  exit 0
fi

ensure_session_dir

if ! is_ultrawork_mode; then
  exit 0
fi

tool_name="$(json_get '.tool_name')"
# Match only Bash — MCP and other tool failures have different recovery
# patterns and aren't covered by core.md:128's "same target" semantics.
if [[ "${tool_name}" != "Bash" ]]; then
  exit 0
fi

# Skip background invocations — spawn success ≠ command success (metis F-7).
run_in_background="$(jq -r '.tool_input.run_in_background // false' <<<"${HOOK_JSON}" 2>/dev/null || printf 'false')"
if [[ "${run_in_background}" == "true" ]]; then
  exit 0
fi

# Compute target hash. Use sha1 to keep state key bounded; first 12 hex
# chars give ~48 bits of distinguishing power — more than enough for the
# per-session collision domain.
_omc_target_hash() {
  local tn="$1" arg="$2" cwd="$3"
  local input="${tn}|${arg}|${cwd}"
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "${input}" | sha1sum | awk '{print $1}' | cut -c1-12
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "${input}" | shasum -a 1 | awk '{print $1}' | cut -c1-12
  else
    # Fallback: cksum gives a 32-bit checksum — narrower but still useful
    # as a per-session distinguisher. Hash collisions just merge two
    # targets' counters; the failure mode is acceptable (false-positive
    # circuit fire) and the cost path is opt-out via `circuit_breaker=off`.
    printf '%s' "${input}" | cksum | awk '{print $1}'
  fi
}

tool_command="$(jq -r '.tool_input.command // empty' <<<"${HOOK_JSON}" 2>/dev/null || true)"
# First positional arg: split on whitespace, take first token. If the
# command has no command (rare), fall back to empty string.
first_arg="${tool_command%% *}"
session_cwd="$(jq -r '.cwd // empty' <<<"${HOOK_JSON}" 2>/dev/null || true)"
target_hash="$(_omc_target_hash "${tool_name}" "${first_arg}" "${session_cwd}")"

now_ts="$(now_epoch)"

# Honor quiet window — if the breaker fired within the last 60 seconds,
# don't increment counters or re-fire. Counter accumulates from the
# subsequent post-quiet-window failure.
quiet_until="$(read_state "circuit_quiet_until")"
quiet_until="${quiet_until:-0}"
if (( now_ts < quiet_until )); then
  exit 0
fi

# Read previous state.
prev_target="$(read_state "circuit_target")"
prev_count="$(read_state "circuit_count")"
prev_count="${prev_count:-0}"

# Determine whether this is a failure.
if omc_hook_tool_failed "${HOOK_JSON}"; then
  # Failure on the current target.
  if [[ "${prev_target}" == "${target_hash}" ]]; then
    new_count=$((prev_count + 1))
    # Cap at 10 internally to defend against pathological accumulation.
    if (( new_count > 10 )); then
      new_count=10
    fi
  else
    new_count=1
  fi

  if (( new_count >= 3 )); then
    # Fire the circuit breaker — reset counter, set quiet window, emit
    # additionalContext via PostToolUse output schema.
    with_state_lock_batch \
      "circuit_target" "" \
      "circuit_count" "" \
      "circuit_quiet_until" "$((now_ts + 60))" \
      "circuit_last_fire_ts" "${now_ts}"

    # Record telemetry. record_gate_event is fire-and-forget; if it
    # fails the breaker still emits its directive (graceful degradation).
    record_gate_event "circuit-breaker" "fire" \
      "target_hash=${target_hash}" "tool=${tool_name}" \
      "first_arg=$(printf '%s' "${first_arg}" | tr -d '\n' | cut -c1-80)" \
      2>/dev/null || true

    target_display="$(printf '%s' "${first_arg}" | cut -c1-60)"
    [[ -z "${target_display}" ]] && target_display="${tool_name}"

    jq -nc --arg ctx "CIRCUIT BROKEN: 3 consecutive failures on target \`${target_display}\` (tool=${tool_name}). Per core.md \"3 failed attempts at the same target — even with argument variations — stop, revert to known-good, document tries, switch approach or delegate to oracle.\" Stop retrying the same command shape; either (1) revert recent changes and try a different approach, or (2) dispatch the \`oracle\` agent for a fresh-context root-cause review. Re-fires suppressed for 60 seconds — use that window to step back, not to retry once more. If this is a legitimate iterative workflow (e.g., TDD red-green cycle), set \`circuit_breaker=off\` in oh-my-claude.conf." '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $ctx
      }
    }'
  else
    # Below threshold — increment counter and keep silent.
    with_state_lock_batch \
      "circuit_target" "${target_hash}" \
      "circuit_count" "${new_count}"
  fi
else
  # Success — reset counter if it was on this target.
  if [[ "${prev_target}" == "${target_hash}" ]] && [[ -n "${prev_count}" ]]; then
    with_state_lock_batch \
      "circuit_target" "" \
      "circuit_count" ""
  fi
  # Else: success on a different target → leave counter for prev_target
  # alone. We track CONSECUTIVE same-target failures; an interleaved
  # success on a different target does not reset.
fi

exit 0
