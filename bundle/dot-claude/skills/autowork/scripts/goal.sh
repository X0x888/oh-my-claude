#!/usr/bin/env bash
# goal.sh — manage a persistent, user-declared GOAL that the stop-guard
# relentless driver pursues across turns until it is verifiably achieved
# or hits a wall it cannot pass alone. Backs the /goal skill — the
# user-facing, VOLUNTARY sibling of the involuntary objective-contract
# gate (the "v1.46-pre Codex /goal port"). Where objective-contract arms
# reactively on coarse big-task detection and caps at 2 blocks, /goal is
# armed deliberately by the user and drives relentlessly (uncapped except
# for the progress-aware stuck-wall escape) until the goal is met.
#
# SCOPE (v1): session-persistent. The goal lives in session_state.json and
# persists across TURNS within a session — Codex's "keep a goal alive
# across turns" Ralph-loop semantic. Cross-SESSION persistence is
# deliberately NOT built here: the No-Out-of-Scope contract sanctions only
# /ulw-resume (involuntary rate-limit kill) for cross-session Stop-survival
# (CHANGELOG [Unreleased] abstraction-critic ruling). A voluntary durable
# goal artifact is a separate, contestable decision; see the /goal SKILL.md
# "Scope and the cross-session question" note.
#
# Subcommands:
#   set "<objective>"   arm the goal (relentless driver engages)
#   status | (none)     print current goal state
#   pause               suspend the driver (goal text preserved)
#   resume              re-engage the driver
#   clear               stand down + wipe goal state
#   done [reason]       mark achieved + wipe goal state (records achievement)
# A bare `goal.sh "<objective>"` with no recognized subcommand is treated
# as `set` so the model cannot fumble the verb.
#
# State writes (ALL stored as strings — read_state_keys returns empty for
# raw JSON numbers, so counters/timestamps must be strings; see
# project_objective_completion_contract_assessment memory):
#   goal_mode_active        "1" while armed
#   goal_objective          verbatim (redacted) objective text
#   goal_set_ts             epoch the goal was set
#   goal_paused             "1" while paused
#   goal_blocks             total goal-driver blocks this session
#   goal_stuck_blocks       consecutive no-progress blocks (escape counter)
#   goal_last_block_edit_ts / goal_last_block_edit_revision
#                           edit generation at the previous goal block
#
# Exit codes:
#   0 — ok
#   2 — bad invocation (missing/empty objective, no session, lifecycle op
#       with no active goal)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common.sh"

if [[ -z "${SESSION_ID:-}" ]]; then
  printf 'goal: no active session (SESSION_ID unset).\n' >&2
  exit 2
fi

_goal_stuck_threshold="${OMC_GOAL_STUCK_THRESHOLD:-3}"
[[ "${_goal_stuck_threshold}" =~ ^[0-9]+$ ]] || _goal_stuck_threshold=3

subcmd="${1:-status}"

case "${subcmd}" in
  set)
    shift
    objective="$*"
    ;;
  status|"")
    objective=""
    ;;
  pause|resume|clear|done)
    objective=""
    ;;
  *)
    # Forgiving: a bare `goal.sh "<objective>"` (no explicit verb) means
    # set-the-goal. Capture the whole argument vector as the objective.
    objective="$*"
    subcmd="set"
    ;;
esac

case "${subcmd}" in
  set)
    if [[ -z "${objective//[[:space:]]/}" ]]; then
      printf 'goal: a non-empty objective is required.\n' >&2
      printf 'usage: goal.sh set "<objective — what should be relentlessly pursued until done?>"\n' >&2
      exit 2
    fi
    # Single-line for clean state + gate-event rows; the driver re-anchors
    # a 600-char excerpt anyway, and multi-line values complicate the
    # RS-delimited state reader. Collapse newlines to spaces, then redact
    # any secrets (the objective is persisted on disk + re-injected into
    # context, same exposure as current_objective which the router redacts).
    # The display copy is normalized here; goal_arm_objective (common.sh,
    # v1.47 — the single arming surface shared with the router auto-arm)
    # re-applies the same normalization idempotently before persisting.
    objective="$(printf '%s' "${objective}" | tr '\n' ' ')"
    objective="$(omc_redact_secrets <<<"${objective}")"
    goal_arm_objective "${objective}" "manual"
    # goal_arm_objective predates monotonic edit generations. Clear the
    # adjacent revision marker here so re-arming cannot inherit progress from
    # a previous goal; the Stop driver persists it on the first block.
    write_state "goal_last_block_edit_revision" ""
    printf 'goal: ARMED. The relentless driver will re-anchor this objective and block Stop\n'
    printf '      until you (a) achieve it — fresh excellence audit + attest **Goal achieved.** —\n'
    if [[ "${_goal_stuck_threshold}" -eq 0 ]]; then
      printf '      with an uncapped drive (goal_stuck_threshold=0: no automatic stuck-wall release).\n'
    else
      printf '      or (b) hit a no-progress wall (%s consecutive stalls auto-release with a surface).\n' "${_goal_stuck_threshold}"
    fi
    printf '  Goal: %s\n' "${objective}"
    printf '  Lifecycle: /goal (status) · /goal pause · /goal resume · /goal clear · /goal done\n'
    # v1.47 honesty fix: the driver lives in stop-guard, which exits before
    # any gate when the session is not in ultrawork mode — an armed goal in
    # a vanilla session is DORMANT, and the banner above would overpromise.
    # The /goal COMMAND path can no longer hit this (the router treats it
    # as a ULW activation trigger); this fires only on direct goal.sh
    # invocations in a non-ULW session (e.g. the model arming a goal via
    # bash outside /ulw).
    if ! is_ultrawork_mode; then
      printf '  NOTE: DORMANT — this session is not in ultrawork mode, so the stop-guard\n'
      printf '        driver cannot engage yet. The /goal command activates ULW itself;\n'
      printf '        a direct goal.sh call does not. Any /ulw prompt activates the session.\n'
    fi
    ;;

  status|"")
    active="$(read_state "goal_mode_active" 2>/dev/null || true)"
    if [[ "${active}" != "1" ]]; then
      printf 'goal: no active goal in this session.\n'
      printf '  Set one with: /goal "<objective>"\n'
      exit 0
    fi
    objective="$(read_state "goal_objective" 2>/dev/null || true)"
    paused="$(read_state "goal_paused" 2>/dev/null || true)"
    blocks="$(read_state "goal_blocks" 2>/dev/null || true)"; blocks="${blocks:-0}"
    stuck="$(read_state "goal_stuck_blocks" 2>/dev/null || true)"; stuck="${stuck:-0}"
    # Priority: paused (explicit user choice) → dormant (driver structurally
    # cannot run — stop-guard exits before any gate outside ultrawork mode;
    # v1.47 honesty fix, the pre-fix status claimed "ARMED (driver active)"
    # in a vanilla session where the driver provably never fires) →
    # gate-off → ARMED.
    if [[ "${paused}" == "1" ]]; then
      printf 'goal: PAUSED (driver suspended — /goal resume to re-engage).\n'
    elif ! is_ultrawork_mode; then
      printf 'goal: SET but DORMANT (session not in ultrawork mode — the stop-guard driver\n'
      printf '      cannot engage until a /ulw or /goal prompt activates the session).\n'
    elif [[ "${OMC_GOAL_GATE:-on}" != "on" ]]; then
      printf 'goal: SET but the driver is disabled (goal_gate=off in oh-my-claude.conf).\n'
    else
      printf 'goal: ARMED (driver active — relentless until achieved).\n'
    fi
    printf '  Objective: %s\n' "${objective}"
    if [[ "${_goal_stuck_threshold}" -eq 0 ]]; then
      printf '  Driver blocks this session: %s (consecutive no-progress: %s; uncapped, no automatic stuck-wall release)\n' \
        "${blocks}" "${stuck}"
    else
      printf '  Driver blocks this session: %s (consecutive no-progress: %s/%s before stuck-wall release)\n' \
        "${blocks}" "${stuck}" "${_goal_stuck_threshold}"
    fi
    ;;

  pause)
    if [[ "$(read_state "goal_mode_active" 2>/dev/null || true)" != "1" ]]; then
      printf 'goal: no active goal to pause.\n' >&2
      exit 2
    fi
    # Loud on a dropped write: a bare `write_state` under `set -euo pipefail`
    # would exit the child silently (before the confirmation print), leaving
    # goal_paused stale on disk — a relentless-driver state that LOOKS paused
    # but isn't, or vice-versa. Surface the failure so it can never masquerade
    # as success (oracle finding: the silent-state-drop mechanism behind the
    # test-goal S1 flake; the symmetric fix is at resume below + the unguarded
    # mktemp in lib/state-io.sh:_write_state_unlocked).
    if ! write_state "goal_paused" "1"; then
      printf 'goal: failed to persist paused state — try again.\n' >&2
      exit 1
    fi
    record_gate_event "goal" "goal-paused" 2>/dev/null || true
    printf 'goal: PAUSED. The relentless driver is suspended; the goal text is preserved.\n'
    printf '  Re-engage with: /goal resume\n'
    ;;

  resume)
    if [[ "$(read_state "goal_mode_active" 2>/dev/null || true)" != "1" ]]; then
      printf 'goal: no active goal to resume.\n' >&2
      exit 2
    fi
    # Loud on a dropped write (see pause above): a silent failure here would
    # leave goal_paused="1" so the driver stays disengaged while the user
    # believes it resumed.
    if ! write_state "goal_paused" ""; then
      printf 'goal: failed to clear paused state — try again.\n' >&2
      exit 1
    fi
    record_gate_event "goal" "goal-resumed" 2>/dev/null || true
    printf 'goal: RESUMED. The relentless driver is re-engaged.\n'
    ;;

  clear)
    with_state_lock_batch \
      "goal_mode_active" "" \
      "goal_objective" "" \
      "goal_set_ts" "" \
      "goal_paused" "" \
      "goal_blocks" "" \
      "goal_stuck_blocks" "" \
      "goal_last_block_edit_ts" "" \
      "goal_last_block_edit_revision" ""
    record_gate_event "goal" "goal-cleared" 2>/dev/null || true
    printf 'goal: CLEARED. The relentless driver has stood down.\n'
    ;;

  done)
    reason="${2:-}"
    with_state_lock_batch \
      "goal_mode_active" "" \
      "goal_objective" "" \
      "goal_set_ts" "" \
      "goal_paused" "" \
      "goal_blocks" "" \
      "goal_stuck_blocks" "" \
      "goal_last_block_edit_ts" "" \
      "goal_last_block_edit_revision" ""
    record_gate_event "goal" "goal-achieved" \
      "reason=${reason:0:200}" 2>/dev/null || true
    if [[ -n "${reason//[[:space:]]/}" ]]; then
      printf 'goal: marked ACHIEVED + stood down. (%s)\n' "${reason}"
    else
      printf 'goal: marked ACHIEVED + stood down.\n'
    fi
    ;;
esac

exit 0
