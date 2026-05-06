#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${SCRIPT_DIR}/common.sh"

SESSION_ID="$(json_get '.session_id')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

# emit_scorecard_stop_context — Render a guard-exhaustion scorecard to
# the user via `systemMessage` (the documented user-visible Stop output
# field). `hookSpecificOutput.additionalContext` is silently dropped by
# Claude Code on Stop. See CLAUDE.md "Stop hook output schema".
emit_scorecard_stop_context() {
  local header="$1"
  local footer="$2"
  local scorecard="$3"

  rm -f "${STATE_ROOT}/.ulw_active"
  # `printf -v` is required for real newlines: bash double-quoted `\n`
  # is two literal characters (backslash + n), and jq's `--arg` passes
  # them through verbatim — the user would otherwise see `\n` glyphs at
  # the header/footer joins. v1.30.0: emit_stop_message (common.sh)
  # encodes the {systemMessage: $body} schema so this site cannot
  # regress to additionalContext.
  local body
  printf -v body '%s\n%s\n%s' "${header}" "${scorecard}" "${footer}"
  emit_stop_message "${body}"
}

last_assistant_message="$(json_get '.last_assistant_message')"
if [[ -n "${last_assistant_message}" ]]; then
  write_state_batch \
    "last_assistant_message" "${last_assistant_message}" \
    "last_assistant_message_ts" "$(now_epoch)"
fi

if ! is_ultrawork_mode; then
  # Clean up sentinel when a non-ULW session ends
  rm -f "${STATE_ROOT}/.ulw_active"
  exit 0
fi

stop_hook_active="$(json_get '.stop_hook_active')"
if [[ "${stop_hook_active}" == "true" ]]; then
  exit 0
fi

has_closeout_label() {
  local kind="$1"
  local text="${2:-}"
  local pattern=""
  case "${kind}" in
    changed)      pattern='\*\*(Changed|Shipped)(\.)?\*\*' ;;
    verification) pattern='\*\*Verification(\.)?\*\*' ;;
    risks)        pattern='\*\*Risks(\.)?\*\*' ;;
    next)         pattern='\*\*Next(\.)?\*\*' ;;
    *) return 1 ;;
  esac
  [[ -n "${text}" ]] || return 1
  printf '%s' "${text}" | grep -Eiq "${pattern}"
}

has_closeout_signal() {
  local kind="$1"
  local text="${2:-}"
  local pattern=""
  case "${kind}" in
    delivery)     pattern='\b(changed|updated|added|fixed|implemented|shipped|refactored|removed|documented|wired)\b' ;;
    verification) pattern='\b(verified|tested|reviewed|linted|validated|passed)\b' ;;
    risks)        pattern='\b(risk|risks|defer(red)?|follow[- ]up|blocked|awaiting|pending|residual)\b' ;;
    *) return 1 ;;
  esac
  [[ -n "${text}" ]] || return 1
  printf '%s' "${text}" | grep -Eiq "${pattern}"
}

read_findings_count_by_status() {
  local target_status="$1"
  [[ -z "${target_status}" ]] && { printf '0'; return 0; }
  [[ -z "${SESSION_ID:-}" ]] && { printf '0'; return 0; }
  local file
  file="$(session_file "findings.json")"
  [[ -f "${file}" ]] || { printf '0'; return 0; }
  jq -r --arg s "${target_status}" \
    '[(.findings // [])[] | select(.status == $s)] | length' \
    "${file}" 2>/dev/null || printf '0'
}

# --- Gate skip check (/ulw-skip) ---
# If the user registered a gate skip, honor it if the edit clock has not
# advanced since registration (new edits invalidate the skip). This prevents
# a user from registering a skip, making more edits, and bypassing gates
# on the new work.
gate_skip_reason="$(read_state "gate_skip_reason")"
if [[ -n "${gate_skip_reason}" ]]; then
  gate_skip_edit_ts="$(read_state "gate_skip_edit_ts")"
  current_edit_ts_for_skip="$(read_state "last_edit_ts")"
  gate_skip_edit_ts="${gate_skip_edit_ts:-0}"
  current_edit_ts_for_skip="${current_edit_ts_for_skip:-0}"

  # Clear the skip flag regardless (single-use)
  with_state_lock_batch "gate_skip_reason" "" "gate_skip_ts" "" "gate_skip_edit_ts" ""

  if [[ "${current_edit_ts_for_skip}" -le "${gate_skip_edit_ts}" ]]; then
    # Edit clock unchanged — skip is valid
    record_gate_skip "${gate_skip_reason}" &
    log_hook "stop-guard" "gate skip honored: ${gate_skip_reason}"
    # v1.34.1+ (data-lens D-001): mark outcome so cross-session
    # session_summary.jsonl distinguishes a clean skip-honored release
    # from a true model abandonment. v1.34.2 (release-reviewer F-1):
    # use "skip-released" specifically for the gate-skip path so the
    # P-004 outcome card downstream does NOT claim credit for gates
    # the user explicitly bypassed via /ulw-skip — those gates fired
    # but were NOT resolved by the model. "released" is now reserved
    # for the truly-clean exit paths (advisory pass, no-edits release).
    with_state_lock write_state "session_outcome" "skip-released" || true
    rm -f "${STATE_ROOT}/.ulw_active"
    exit 0
  else
    log_hook "stop-guard" "gate skip invalidated: edits occurred after registration (skip_edit_ts=${gate_skip_edit_ts}, current=${current_edit_ts_for_skip})"
    # Fall through to normal gate logic
  fi
fi

# v1.27.0 (F-018): bulk-read 5 always-together state keys in one jq fork
# instead of 5 sequential read_state calls (saves ~30-40ms on macOS bash 3.2).
# Invariant: argv length === case-branch count (5 keys → 5 branches 0..4).
# Adding a key requires (a) extending the read_state_keys argv below AND
# (b) extending the case statement above. read_state_keys always emits
# exactly N lines for N args (jq's // "" + corrupt/missing fallbacks),
# so the case statement always sees a complete frame.
# v1.34.0: read_state_keys is RS-delimited (byte 0x1e) so multi-line
# values like `current_objective` no longer overflow into later
# positional slots. See state-io.sh:read_state_keys for the contract.
_sg_idx=0
while IFS= read -r -d $'\x1e' _sg_line; do
  case "${_sg_idx}" in
    0) current_objective="${_sg_line}" ;;
    1) task_intent="${_sg_line}" ;;
    2) last_user_prompt_ts="${_sg_line}" ;;
    3) session_handoff_blocks="${_sg_line}" ;;
    4) last_edit_ts="${_sg_line}" ;;
  esac
  _sg_idx=$((_sg_idx + 1))
done < <(read_state_keys \
  "current_objective" \
  "task_intent" \
  "last_user_prompt_ts" \
  "session_handoff_blocks" \
  "last_edit_ts")
session_handoff_blocks="${session_handoff_blocks:-0}"

if ! is_execution_intent_value "${task_intent}"; then
  # Advisory quality check: for advisory tasks over codebases, verify that
  # actual code inspection happened before allowing the response to finalize.
  if [[ "${task_intent}" == "advisory" ]]; then
    task_domain_val="$(task_domain)"
    task_domain_val="${task_domain_val:-general}"
    if [[ "${task_domain_val}" == "coding" || "${task_domain_val}" == "mixed" ]]; then
      advisory_verify_ts="$(read_state "last_advisory_verify_ts")"
      verify_ts="$(read_state "last_verify_ts")"
      advisory_guard_blocks="$(read_state "advisory_guard_blocks")"
      advisory_guard_blocks="${advisory_guard_blocks:-0}"

      if [[ -z "${advisory_verify_ts}" && -z "${verify_ts}" ]] && [[ "${advisory_guard_blocks}" -lt 1 ]]; then
        write_state "advisory_guard_blocks" "$((advisory_guard_blocks + 1))"
        record_gate_event "advisory" "block" "block_count=1" "block_cap=1"
        advisory_recovery="$(format_gate_recovery_line "read or search the affected code (Read/Grep/Glob), then re-issue your summary citing files inspected. To bypass once with reason, run /ulw-skip.")"
        # v1.34.1+ (P-002): tighter advisory block.
        emit_stop_block "[Advisory gate · 1/1] this is an advisory task over a codebase, but no code inspection or verification was recorded.
Ground your recommendation in the actual code before finalizing.${advisory_recovery}"
        exit 0
      fi
    fi
  fi

  if [[ -z "${last_edit_ts}" || -z "${last_user_prompt_ts}" || "${last_edit_ts}" -lt "${last_user_prompt_ts}" ]]; then
    # v1.34.1+ (D-001): advisory-clean release (no fresh edits since prompt).
    # Distinguishes from "abandoned" in cross-session analytics.
    with_state_lock write_state "session_outcome" "released" || true
    exit 0
  fi
fi

# /ulw-pause carve-out: when the assistant declared a legitimate user-
# decision pause this turn (taste, policy, credible-approach split),
# the session-handoff gate must NOT fire. The pause flag is set by
# bundle/dot-claude/skills/autowork/scripts/ulw-pause.sh and cleared
# automatically at the next user prompt by prompt-intent-router.sh.
# This is the only structured "I'm legitimately paused, not stalling"
# signal in the harness — see /ulw-pause SKILL.md for usage.
ulw_pause_active="$(read_state "ulw_pause_active" 2>/dev/null || true)"
if [[ "${ulw_pause_active}" != "1" ]] \
  && [[ -n "${last_assistant_message}" ]] \
  && has_unfinished_session_handoff "${last_assistant_message}" \
  && ! is_checkpoint_request "${current_objective}"; then
  if [[ "${session_handoff_blocks}" -lt 2 ]]; then
    write_state "session_handoff_blocks" "$((session_handoff_blocks + 1))"
    record_gate_event "session-handoff" "block" \
      "block_count=$((session_handoff_blocks + 1))" "block_cap=2"
    handoff_recovery="$(format_gate_recovery_line "continue the deferred work now in this session, OR ask the user explicitly whether they want a checkpoint. If you are pausing because the user must decide something you cannot decide autonomously, run /ulw-pause <reason> instead — that signals a legitimate pause without tripping this gate. To bypass once with reason, run /ulw-skip.")"
    # v1.34.1+ (P-002): tighter session-handoff block; recovery line
    # already names the three legitimate continuation options. Keep the
    # literal "deferred remaining work" phrase — locked by e2e seq-G.
    emit_stop_block "[Session-handoff gate · $((session_handoff_blocks + 1))/2] your last response deferred remaining work to a future session, but the user did not request a checkpoint.
Continue the work now (do not stop with 'next wave', 'ready for a new session' language).${handoff_recovery}"
    exit 0
  fi
fi

# Exemplifying-scope checklist gate: when a fresh execution prompt uses
# "for instance" / "e.g." / "such as" / "as needed" style markers, the
# router records exemplifying_scope_required=1. A soft directive alone is
# too easy for the model to ignore, so this gate requires an auditable
# checklist: enumerate sibling class items, then mark each shipped or
# consciously declined with a concrete WHY via record-scope-checklist.sh.
if [[ "${OMC_EXEMPLIFYING_SCOPE_GATE:-on}" == "on" ]] \
  && is_execution_intent_value "${task_intent}" \
  && [[ "$(read_state "exemplifying_scope_required")" == "1" ]]; then
  _es_file="$(session_file "exemplifying_scope.json")"
  _es_prompt_ts="$(read_state "exemplifying_scope_prompt_ts")"
  _es_prompt_ts="${_es_prompt_ts:-0}"
  [[ "${_es_prompt_ts}" =~ ^[0-9]+$ ]] || _es_prompt_ts=0

  _es_missing=1
  _es_pending=0
  _es_total=0
  _es_scorecard="  (no checklist recorded)"

  if [[ -f "${_es_file}" ]]; then
    _es_file_prompt_ts="$(jq -r '.source_prompt_ts // 0' "${_es_file}" 2>/dev/null || printf '0')"
    _es_total="$(jq -r '(.items // []) | length' "${_es_file}" 2>/dev/null || printf '0')"
    _es_pending="$(jq -r '[.items[]? | select(.status == "pending")] | length' "${_es_file}" 2>/dev/null || printf '0')"
    [[ "${_es_total}" =~ ^[0-9]+$ ]] || _es_total=0
    [[ "${_es_pending}" =~ ^[0-9]+$ ]] || _es_pending=0
    if [[ "${_es_file_prompt_ts}" == "${_es_prompt_ts}" && "${_es_total}" -gt 0 ]]; then
      _es_missing=0
    else
      _es_scorecard="  (checklist exists but belongs to a different prompt or has no items)"
    fi
    if [[ "${_es_total}" -gt 0 ]]; then
      _es_scorecard="$(jq -r '
        (.items // [])
        | map("  - [" + (.status // "pending") + "] " + .id + ": " + .summary
              + (if (.reason // "") != "" then " -- " + .reason else "" end))
        | .[]
      ' "${_es_file}" 2>/dev/null || printf '  (could not read checklist)')"
    fi
  fi

  if [[ "${_es_missing}" -eq 1 || "${_es_pending}" -gt 0 ]]; then
    _es_blocks="$(read_state "exemplifying_scope_blocks")"
    _es_blocks="${_es_blocks:-0}"
    [[ "${_es_blocks}" =~ ^[0-9]+$ ]] || _es_blocks=0
    _es_cap=2

    if [[ "${_es_blocks}" -lt "${_es_cap}" || "${OMC_GUARD_EXHAUSTION_MODE}" == "block" ]]; then
      if [[ "${_es_blocks}" -lt "${_es_cap}" ]]; then
        write_state "exemplifying_scope_blocks" "$((_es_blocks + 1))"
        _es_next_block="$((_es_blocks + 1))"
      else
        _es_next_block="${_es_blocks}"
      fi
      record_gate_event "exemplifying-scope" "block" \
        "block_count=${_es_next_block}" \
        "block_cap=${_es_cap}" \
        "missing_checklist=${_es_missing}" \
        "pending_count=${_es_pending}" \
        "total_count=${_es_total}"
      _es_recovery="$(format_gate_recovery_line "inspect the exemplified surface, run \`~/.claude/skills/autowork/scripts/record-scope-checklist.sh init\` with the sibling items, then mark each item \`shipped\` or \`declined <concrete why>\`. Bare 'out of scope' / 'not in scope' is not a reason. To bypass once with reason, run /ulw-skip.")"
      if [[ "${_es_missing}" -eq 1 ]]; then
        _es_reason="[Exemplifying-scope gate · ${_es_next_block}/${_es_cap}] this prompt used example markers, so the example is one item from a class, but no current scope checklist was recorded. ULW must not silently implement only the literal example. Record the sibling items a veteran would bundle into this pass before finalizing.${_es_recovery}"
      else
        _es_reason="[Exemplifying-scope gate · ${_es_next_block}/${_es_cap}] ${_es_pending}/${_es_total} exemplified-scope checklist item(s) are still pending. Ship them, or mark individual items declined with a concrete WHY. Current checklist:
${_es_scorecard}
${_es_recovery}"
      fi
      if [[ "${OMC_GUARD_EXHAUSTION_MODE}" == "block" && "${_es_blocks}" -ge "${_es_cap}" ]]; then
        _es_reason="${_es_reason} BLOCK MODE: this gate will not release until the checklist is satisfied."
      fi
      emit_stop_block "${_es_reason}"
      exit 0
    fi

    with_state_lock_batch \
      "guard_exhausted" "$(now_epoch)" \
      "guard_exhausted_detail" "exemplifying_scope_missing=${_es_missing},pending=${_es_pending}" \
      "session_outcome" "exhausted"
    record_gate_event "exemplifying-scope" "exhausted" \
      "block_count=${_es_blocks}" \
      "block_cap=${_es_cap}" \
      "missing_checklist=${_es_missing}" \
      "pending_count=${_es_pending}" \
      "total_count=${_es_total}"
    emit_scorecard_stop_context \
      "EXEMPLIFYING-SCOPE SCORECARD (gate exhausted after ${_es_cap} blocks):" \
      "The exemplifying-scope gate released without full checklist satisfaction. Name the remaining scope risk in your final summary." \
      "${_es_scorecard}"
    exit 0
  fi
fi

# Wave-shape gate (F-013): block once when the active wave plan is
# under-segmented per the canonical Phase 8 rule (avg <3 findings/wave
# on a master list of \u22655 findings AND \u22652 waves planned). This catches
# the over-segmentation pattern that produced the v1.21.0 5\u00d71-wave UX
# regression where the model atomized findings into single-finding waves
# and stopped after a polish-grade quality cycle on each one.
#
# Cap = 1. The model gets one chance to reconcile the plan: either
# re-issue assign-wave with merged surfaces, or explicitly accept the
# plan with /ulw-skip <reason> if a single-finding wave is genuinely
# load-bearing for that surface. Fires AFTER session-handoff (already
# checked above) but BEFORE discovered-scope so the structural plan
# error is surfaced before the model races through fixes.
if [[ "${OMC_DISCOVERED_SCOPE}" == "on" ]] \
  && is_execution_intent_value "${task_intent}" \
  && is_wave_plan_under_segmented; then
  wave_shape_blocks="$(read_state "wave_shape_blocks")"
  wave_shape_blocks="${wave_shape_blocks:-0}"
  if [[ "${wave_shape_blocks}" -lt 1 ]]; then
    write_state "wave_shape_blocks" "$((wave_shape_blocks + 1))"
    _ws_total="$(read_total_findings_count)"
    _ws_waves="$(read_active_wave_total)"
    _ws_avg=$((_ws_total / _ws_waves))
    record_gate_event "wave-shape" "block" \
      "block_count=1" "block_cap=1" \
      "total_findings=${_ws_total}" \
      "wave_total=${_ws_waves}" \
      "avg_per_wave=${_ws_avg}"
    wave_shape_recovery="$(format_gate_recovery_line "merge adjacent wave surfaces so the plan reaches avg ≥3 findings/wave (5-10/wave is the canonical target; 3 is the minimum). Re-issue \`record-finding-list.sh assign-wave\` with the merged plan — note that re-issuing assign-wave alone won't re-arm this gate, so reconcile in one pass. To bypass once with reason — e.g., 'each finding owns a genuinely separate critical surface' — run /ulw-skip.")"
    # v1.34.1+ (P-002): tighter block message; canonical 5-10/wave rule
    # is documented in council/SKILL.md Step 8.
    emit_stop_block "[Wave-shape gate · 1/1] wave plan under-segmented: ${_ws_total} findings across ${_ws_waves} waves (avg ${_ws_avg}/wave; canonical floor is ≥3, target 5-10).
Reconcile the plan before continuing — merge adjacent waves or accept the shape with /ulw-skip <reason> if a single-finding wave is intentional here.${wave_shape_recovery}"
    exit 0
  fi
fi

# Discovered-scope gate: when advisory specialists (council lenses, metis,
# briefing-analyst) emit findings during this session, the model must
# explicitly account for each one before stopping — either ship the fix,
# defer with a stated reason, or call it out as known follow-up risk.
# Silent skipping is the failure mode this gate catches.
if [[ "${OMC_DISCOVERED_SCOPE}" == "on" ]] \
  && is_execution_intent_value "${task_intent}"; then
  scope_file="$(session_file "discovered_scope.jsonl")"
  if [[ -f "${scope_file}" ]]; then
    pending_count="$(read_pending_scope_count)"
    discovered_scope_blocks="$(read_state "discovered_scope_blocks")"
    discovered_scope_blocks="${discovered_scope_blocks:-0}"
    # Cap normally fixed at 2 (block twice, then release with scorecard).
    # When a SUBSTANTIVE wave plan is active (Phase 8 of /council recorded
    # findings.json with N waves AND the plan is NOT under-segmented),
    # raise the cap to N+1 so the gate stays useful across multiple
    # legitimate wave-by-wave commits instead of silently releasing after
    # wave 2 with 20+ findings still pending.
    #
    # F-014 polarity fix: under-segmented plans (avg <3 findings/wave on
    # a master list of >=5 findings) do NOT raise the cap. Closes the
    # bug where 5x1-finding wave plans got cap=6 and released after the
    # 5th narrow wave even though the canonical bar wasn't met. The
    # wave-shape gate above is the front-line defense; the cap polarity
    # is the backstop for plans that bypass it via /ulw-skip.
    wave_total="$(read_active_wave_total)"
    if [[ "${wave_total}" -gt 0 ]] && ! is_wave_plan_under_segmented; then
      scope_block_cap=$((wave_total + 1))
    else
      scope_block_cap=2
    fi
    if [[ "${pending_count}" -gt 0 && "${discovered_scope_blocks}" -lt "${scope_block_cap}" ]]; then
      write_state "discovered_scope_blocks" "$((discovered_scope_blocks + 1))"
      scorecard="$(build_discovered_scope_scorecard 8 || true)"
      wave_progress=""
      if [[ "${wave_total}" -gt 0 ]]; then
        # Counts waves with status="completed", not in-progress — see common.sh.
        waves_completed="$(read_active_waves_completed)"
        wave_progress=" Wave plan: ${waves_completed}/${wave_total} waves completed."
      fi
      record_gate_event "discovered-scope" "block" \
        "block_count=$((discovered_scope_blocks + 1))" \
        "block_cap=${scope_block_cap}" \
        "pending_count=${pending_count}" \
        "wave_total=${wave_total}" \
        "waves_completed=${waves_completed:-0}"
      # v1.34.1+ (P-002 / X-001 / O-003): tighter block-message UX. The
      # full discursive rationale ("ship inline > wave-append > defer with
      # WHY > call-out as risk") lives in core.md "Wave-append before
      # defer" and skills/SKILL.md's deferral-verb decision tree. The
      # block message names the trigger, shows the pending list, and
      # routes to the recommended actions — the discursive escalation
      # ladder is for repeat blocks, not first-touch. Keep the
      # record-serendipity.sh reminder inline (Serendipity Rule is
      # invisible if not surfaced at gate-fire — locked by
      # tests/test-discovered-scope.sh T28).
      scope_recovery="$(format_gate_recovery_line "ship the fix inline (preferred for same-surface findings), OR /mark-deferred <named-WHY> for bulk defer (validator rejects bare \"out of scope\" / \"follow-up\" / \"later\"; use \"requires X\" / \"blocked by Y\" / \"awaiting Z\"), OR /ulw-skip <reason> to bypass once. If you fixed a verified adjacent defect on the same code path, log it via record-serendipity.sh per the Serendipity Rule.")"
      emit_stop_block "[Discovered-scope gate · $((discovered_scope_blocks + 1))/${scope_block_cap}] ${pending_count} advisory finding(s) captured this session not addressed in your summary.${wave_progress}
Top pending (severity-ranked):
${scorecard}${scope_recovery}"
      exit 0
    fi
  fi
fi

if [[ -z "${last_edit_ts}" ]]; then
  # v1.34.1+ (D-001): no edits made — released without work to verify.
  with_state_lock write_state "session_outcome" "released" || true
  exit 0
fi

# v1.27.0 (F-018): bulk-read 6 always-together state keys in one jq fork.
# Invariant: argv length === case-branch count (6 keys → 6 branches 0..5).
# v1.34.0: RS-delimited read protects against multi-line values stored
# in any of the read clocks (rare today but cheap insurance).
_sg2_idx=0
while IFS= read -r -d $'\x1e' _sg2_line; do
  case "${_sg2_idx}" in
    0) last_review_ts="${_sg2_line}" ;;
    1) last_doc_review_ts="${_sg2_line}" ;;
    2) last_verify_ts="${_sg2_line}" ;;
    3) last_code_edit_ts="${_sg2_line}" ;;
    4) last_doc_edit_ts="${_sg2_line}" ;;
    5) guard_blocks="${_sg2_line}" ;;
  esac
  _sg2_idx=$((_sg2_idx + 1))
done < <(read_state_keys \
  "last_review_ts" \
  "last_doc_review_ts" \
  "last_verify_ts" \
  "last_code_edit_ts" \
  "last_doc_edit_ts" \
  "stop_guard_blocks")
task_domain="$(task_domain)"
task_domain="${task_domain:-general}"
guard_blocks="${guard_blocks:-0}"

missing_review=0
missing_verify=0

# --- missing_review computation ---
#
# Two independent clocks:
#   last_code_edit_ts / last_review_ts      → quality-reviewer path
#   last_doc_edit_ts  / last_doc_review_ts  → editor-critic path
#
# If neither clock is populated (resumed session from pre-fix state),
# fall back to the legacy last_edit_ts comparison so older sessions
# continue to gate correctly.

need_code_review=0
need_doc_review=0

if [[ -z "${last_code_edit_ts}" && -z "${last_doc_edit_ts}" ]]; then
  # Legacy fallback — treat last_edit_ts as generic code edit for the review gate.
  if [[ -z "${last_review_ts}" || "${last_review_ts}" -lt "${last_edit_ts}" ]]; then
    missing_review=1
    need_code_review=1
  fi
else
  if [[ -n "${last_code_edit_ts}" ]]; then
    if [[ -z "${last_review_ts}" || "${last_review_ts}" -lt "${last_code_edit_ts}" ]]; then
      need_code_review=1
    fi
  fi
  if [[ -n "${last_doc_edit_ts}" ]]; then
    if [[ -z "${last_doc_review_ts}" || "${last_doc_review_ts}" -lt "${last_doc_edit_ts}" ]]; then
      need_doc_review=1
    fi
  fi
  if [[ "${need_code_review}" -eq 1 || "${need_doc_review}" -eq 1 ]]; then
    missing_review=1
  fi
fi

# --- missing_verify computation ---
#
# Verification only applies to code edits. A doc-only edit (CHANGELOG,
# README) must not re-trigger `npm test`. Key off last_code_edit_ts
# when available; fall back to last_edit_ts for legacy sessions.

verify_clock="${last_code_edit_ts:-${last_edit_ts}}"

case "${task_domain}" in
  coding|mixed)
    # Only require verification if there were code edits at some point.
    # Pure-doc sessions in coding domain (touching only CHANGELOG) skip verify.
    if [[ -n "${last_code_edit_ts}" ]] || [[ -z "${last_doc_edit_ts}" ]]; then
      if [[ -z "${last_verify_ts}" || "${last_verify_ts}" -lt "${verify_clock}" ]]; then
        missing_verify=1
      fi
    fi
    ;;
  *)
    missing_verify=0
    ;;
esac

# Check if verification ran but the tests actually failed
verify_failed=0
if [[ "${missing_verify}" -eq 0 ]]; then
  case "${task_domain}" in
    coding|mixed)
      verify_outcome="$(read_state "last_verify_outcome")"
      if [[ "${verify_outcome}" == "failed" ]]; then
        verify_failed=1
      fi
      ;;
  esac
fi

# Low-confidence verification: if verification ran but confidence is below
# threshold, treat it as insufficient. A `bash -n file.sh` (confidence ~30)
# should not satisfy the same gate as `npm test` (confidence 70+).
verify_low_confidence=0
if [[ "${missing_verify}" -eq 0 && "${verify_failed}" -eq 0 ]]; then
  case "${task_domain}" in
    coding|mixed)
      last_verify_confidence="$(read_state "last_verify_confidence")"
      if [[ -n "${last_verify_confidence}" && "${last_verify_confidence}" =~ ^[0-9]+$ && "${last_verify_confidence}" -lt "${OMC_VERIFY_CONFIDENCE_THRESHOLD}" ]]; then
        verify_low_confidence=1
      fi
      ;;
  esac
fi

# Check if review ran but findings were not addressed (no edits after review).
# Use the effective edit clock — last_code_edit_ts (preferred) falling back
# to last_edit_ts so legacy sessions keep behaving correctly.
review_unremediated=0
if [[ "${missing_review}" -eq 0 ]]; then
  review_had_findings="$(read_state "review_had_findings")"
  effective_edit_ts="${last_code_edit_ts:-${last_edit_ts}}"
  if [[ "${review_had_findings}" == "true" && -n "${last_review_ts}" && "${effective_edit_ts}" -lt "${last_review_ts}" ]]; then
    review_unremediated=1
  fi
fi

if [[ "${task_domain}" == "writing" || "${task_domain}" == "research" || "${task_domain}" == "operations" || "${task_domain}" == "general" ]]; then
  reason="[Quality gate · $((guard_blocks + 1))/3] the deliverable changed but the final quality loop is incomplete."
else
  reason="[Quality gate · $((guard_blocks + 1))/3] edits were made but the final quality loop is incomplete."
fi

if [[ "${missing_review}" -eq 0 && "${missing_verify}" -eq 0 && "${verify_failed}" -eq 0 && "${verify_low_confidence}" -eq 0 && "${review_unremediated}" -eq 0 ]]; then
  # --- Review coverage gate (Check 4, formerly "Dimension gate") ---
  #
  # Standard gates passed. For complex tasks (unique edit count above
  # the dimension-gate threshold), require the prescribed reviewer
  # sequence. Each reviewer owns a distinct review dimension; the gate
  # blocks with a message naming the specific next reviewer to run.
  #
  # Only active when gate_level=full. basic and standard skip this gate.

  if [[ "${OMC_GATE_LEVEL}" == "full" ]]; then
  required_dims="$(get_required_dimensions)"
  if [[ -n "${required_dims}" ]]; then
    missing_dims="$(missing_dimensions "${required_dims}")"

    # Reorder missing dims by risk priority
    if [[ -n "${missing_dims}" ]]; then
      _profile="$(get_project_profile 2>/dev/null || true)"
      missing_dims="$(order_dimensions_by_risk "${missing_dims}" "${_profile}")"
    fi

    if [[ -n "${missing_dims}" ]]; then
      # Build human-readable descriptions for the missing reviews
      _missing_descriptions=""
      for _md in ${missing_dims//,/ }; do
        _desc="$(describe_dimension "${_md}")"
        _missing_descriptions="${_missing_descriptions:+${_missing_descriptions}, }${_desc}"
      done

      # Resumed-session first-stop grace: skip the review coverage gate
      # once when no dimensions have been ticked yet in this resumed session.
      resume_src="$(read_state "resume_source_session_id")"
      dim_grace_used="$(read_state "dimension_resume_grace_used")"
      any_dim_ticked=0
      for _tok in ${required_dims//,/ }; do
        tick_ts_val="$(read_state "$(_dim_key "${_tok}")")"
        if [[ -n "${tick_ts_val}" ]]; then
          any_dim_ticked=1
          break
        fi
      done

      if [[ -n "${resume_src}" && "${any_dim_ticked}" -eq 0 && "${dim_grace_used}" != "1" ]]; then
        write_state "dimension_resume_grace_used" "1"
        log_hook "stop-guard" "review coverage gate: resumed-session grace granted"
      else
        dim_blocks="$(read_state "dimension_guard_blocks")"
        dim_blocks="${dim_blocks:-0}"

        if [[ "${dim_blocks}" -lt 3 ]]; then
          write_state "dimension_guard_blocks" "$((dim_blocks + 1))"
          next_dim="${missing_dims%%,*}"
          next_reviewer="$(reviewer_for_dimension "${next_dim}")"
          next_description="$(describe_dimension "${next_dim}")"

          # Build a progress checklist so the block message shows where
          # the session stands, not just what is missing. This transforms
          # "you are blocked again" into visible progress.
          _total_dims=0
          _done_dims=0
          _checklist=""
          for _rd in ${required_dims//,/ }; do
            _total_dims=$((_total_dims + 1))
            _rd_desc="$(describe_dimension "${_rd}")"
            _rd_reviewer="$(reviewer_for_dimension "${_rd}")"
            if is_dimension_valid "${_rd}"; then
              _done_dims=$((_done_dims + 1))
              _checklist="${_checklist}\n  [done] ${_rd_desc}"
            elif [[ "${_rd}" == "${next_dim}" ]]; then
              _checklist="${_checklist}\n  [NEXT] ${_rd_desc} -> run \`${_rd_reviewer}\`"
            else
              _checklist="${_checklist}\n  [    ] ${_rd_desc}"
            fi
          done

          dim_reason="[Review coverage · $((dim_blocks + 1))/3 · ${_done_dims}/${_total_dims} dimensions] complex task requires prescribed review coverage. Progress:${_checklist}\nNext step: run \`${next_reviewer}\` to cover ${next_description}. Each reviewer owns a distinct review area — do not substitute or reorder. After the reviewer returns, address any findings, then retry stop. After completing this, restate your key deliverable summary at the end of your response."
          if [[ "${dim_blocks}" -ge 2 ]]; then
            dim_reason="${dim_reason} NOTE: this is the final review-coverage block — the next stop attempt will bypass this check."
          fi
          record_gate_event "review-coverage" "block" \
            "block_count=$((dim_blocks + 1))" "block_cap=3" \
            "missing_dims=${missing_dims}" \
            "next_reviewer=${next_reviewer}" \
            "done_dims=${_done_dims}" "total_dims=${_total_dims}"
          emit_stop_block "${dim_reason}"
          exit 0
        else
          # Review coverage gate exhaustion: handle based on mode
          with_state_lock_batch \
            "guard_exhausted" "$(now_epoch)" \
            "guard_exhausted_detail" "dimensions_missing=${missing_dims}" \
            "session_outcome" "exhausted"
          log_hook "stop-guard" "review coverage gate exhausted after 3 blocks: missing=${missing_dims}"
          scorecard="$(build_quality_scorecard)"

          case "${OMC_GUARD_EXHAUSTION_MODE}" in
            block)
              dim_reason="[Review coverage · BLOCK MODE] Guard exhaustion reached but block mode prevents release. QUALITY SCORECARD:\n${scorecard}\nMissing: ${_missing_descriptions}. Address the remaining reviews or switch to guard_exhaustion_mode=scorecard."
              emit_stop_block "${dim_reason}"
              exit 0
              ;;
            scorecard)
              log_hook "stop-guard" "review coverage gate exhausted (scorecard mode): emitting scorecard"
              # v1.27.0 (F-024): scorecard footer is now actionable.
              # Names the concrete recoveries the user/model can take
              # when the gate releases without full completion, instead
              # of the prior passive "note any gaps".
              emit_scorecard_stop_context \
                "QUALITY SCORECARD (review coverage gate exhausted after 3 blocks):" \
                "The review coverage gate released without full completion. Recovery options: (a) restate the missing reviewer dimensions in your final summary so the user can audit them; (b) for each missing dimension shown above, dispatch the corresponding reviewer (quality-reviewer for defects, excellence-reviewer for completeness, design-reviewer for visual craft, editor-critic for prose, metis for plan stress-tests) — even one focused pass converts a scorecard release into a clean release; (c) if the missing dimensions are genuinely out of scope for this task, name the explicit reason in your summary (a session that ships scorecard-released work without naming the gap is the anti-pattern this gate exists to surface)." \
                "${scorecard}"
              exit 0
              ;;
            *)
              rm -f "${STATE_ROOT}/.ulw_active"
              exit 0
              ;;
          esac
        fi
      fi
    fi
  fi
  fi # end gate_level=full (review coverage gate)

  # --- Excellence gate (Check 5) ---
  #
  # Active when gate_level is full or standard. Requires excellence-reviewer
  # for complex tasks (3+ files edited). On tasks that already satisfied
  # the review coverage gate (which ticks completeness via excellence-reviewer),
  # this check is a no-op because last_excellence_review_ts will be current.

  if [[ "${OMC_GATE_LEVEL}" == "full" || "${OMC_GATE_LEVEL}" == "standard" ]]; then
  edited_files_log="$(session_file "edited_files.log")"
  unique_edited_count=0
  if [[ -f "${edited_files_log}" ]]; then
    unique_edited_count="$(sort -u "${edited_files_log}" | wc -l | tr -d '[:space:]')"
  fi

  last_excellence_review_ts="$(read_state "last_excellence_review_ts")"
  excellence_guard_triggered="$(read_state "excellence_guard_triggered")"

  if [[ "${unique_edited_count}" -ge "${OMC_EXCELLENCE_FILE_COUNT}" ]] \
    && [[ -z "${last_excellence_review_ts}" || "${last_excellence_review_ts}" -lt "${last_edit_ts}" ]] \
    && [[ "${excellence_guard_triggered}" != "1" ]]; then
    write_state "excellence_guard_triggered" "1"
    record_gate_event "excellence" "block" "block_count=1" "block_cap=1" \
      "edited_count=${unique_edited_count}"
    excellence_recovery="$(format_gate_recovery_line "dispatch the excellence-reviewer agent on the wave diff, then restate your deliverable summary. To bypass once with reason (e.g., already self-audited), run /ulw-skip.")"
    # v1.34.1+ (P-002): tighter excellence-gate block.
    emit_stop_block "[Excellence gate · 1/1] review/verify passed, but this is a complex task (${unique_edited_count} files edited).
Run excellence-reviewer for fresh-eyes holistic evaluation (completeness, unknown unknowns, polish a veteran would add) before finalizing.${excellence_recovery}"
    exit 0
  fi
  fi # end gate_level full|standard (excellence gate)

  # --- Metis-on-plan gate (Check 6, v1.19.0) ---
  #
  # Active when OMC_METIS_ON_PLAN_GATE=on AND record-plan.sh marked the
  # last plan as complex (plan_complexity_high=1). Blocks Stop until
  # metis has run a stress-test review on the current plan, catching
  # the bias-blindness case where the main thread proceeds confidently
  # from a complex plan that no second-opinion agent has audited.
  #
  # Independent of OMC_GATE_LEVEL — opt-in users get this gate even on
  # basic level, since the whole point is to catch a class of error the
  # standard gates miss. record-plan.sh resets metis_gate_blocks on
  # every fresh plan, so the cap=1 semantic is "block once per plan
  # cycle", not "block once per session".
  if [[ "${OMC_METIS_ON_PLAN_GATE}" == "on" ]]; then
    plan_complexity_high="$(read_state "plan_complexity_high")"
    has_plan="$(read_state "has_plan")"
    plan_ts="$(read_state "plan_ts")"
    last_metis_review_ts="$(read_state "last_metis_review_ts")"
    metis_gate_blocks="$(read_state "metis_gate_blocks")"
    metis_gate_blocks="${metis_gate_blocks:-0}"

    # Treat equality as stale (`<=`, not `<`): if both timestamps fall
    # in the same second, the metis review either preceded the plan or
    # was racing it — neither qualifies as a real stress-test of the
    # current plan. Strictly fresh metis runs land at plan_ts + N where
    # N >= 1s (a real review takes much longer than that).
    metis_stale_or_missing=0
    if [[ -z "${last_metis_review_ts}" ]]; then
      metis_stale_or_missing=1
    elif [[ -n "${plan_ts}" ]] && (( last_metis_review_ts <= plan_ts )); then
      metis_stale_or_missing=1
    fi

    if [[ "${plan_complexity_high}" == "1" ]] \
        && [[ "${has_plan}" == "true" ]] \
        && [[ "${metis_stale_or_missing}" -eq 1 ]] \
        && (( metis_gate_blocks < 1 )); then
      plan_complexity_signals="$(read_state "plan_complexity_signals")"
      write_state "metis_gate_blocks" "$((metis_gate_blocks + 1))"
      record_gate_event "metis-on-plan" "block" \
        "block_count=1" "block_cap=1" \
        "complexity_signals=${plan_complexity_signals}"
      metis_recovery="$(format_gate_recovery_line "dispatch the metis agent on the current plan to stress-test for hidden assumptions, missing constraints, and weak validation. To bypass once with reason (e.g., simple greenfield plan), run /ulw-skip.")"
      # v1.34.1+ (P-002): tighter metis-on-plan block.
      emit_stop_block "[Metis-on-plan gate · 1/1] plan flagged high-complexity (${plan_complexity_signals}) but no metis stress-test recorded since the plan landed.
Run metis to pressure-test for wrong-abstraction / missing-constraint risks before execution.${metis_recovery}"
      exit 0
    fi
  fi

  # --- Delivery-contract gate (prompt-time + inferred contract) ---
  #
  # v1 (prompt-time, v1.33.0): the router records explicit adjacent
  # deliverables and commit expectations from the prompt wording.
  # v2 (inferred, v1.34.0): refresh inferred surfaces from the actual
  # edits — `code edited but no test`, `VERSION bumped without
  # CHANGELOG`, `conf flag added without parser touched`, `migration
  # without release notes`. Both layers feed the same gate so the model
  # gets a single audit-ready blocker list instead of two narrowly-
  # framed ones.
  refresh_inferred_contract || true
  contract_blockers_prompt="$(delivery_contract_blocking_items)"
  contract_blockers_inferred="$(inferred_contract_blocking_items)"
  contract_blockers=""
  if [[ -n "${contract_blockers_prompt}" ]]; then
    contract_blockers="${contract_blockers_prompt}"
  fi
  if [[ -n "${contract_blockers_inferred}" ]]; then
    if [[ -n "${contract_blockers}" ]]; then
      contract_blockers="${contract_blockers}"$'\n'"${contract_blockers_inferred}"
    else
      contract_blockers="${contract_blockers_inferred}"
    fi
  fi
  if [[ -n "${contract_blockers}" ]]; then
    contract_blocker_count="$(printf '%s\n' "${contract_blockers}" | awk 'NF{c++} END{print c+0}')"
    contract_blocker_prompt_count="$(printf '%s\n' "${contract_blockers_prompt}" | awk 'NF{c++} END{print c+0}')"
    contract_blocker_inferred_count="$(printf '%s\n' "${contract_blockers_inferred}" | awk 'NF{c++} END{print c+0}')"
    record_gate_event "delivery-contract" "block" \
      "remaining_count=${contract_blocker_count}" \
      "prompt_blocker_count=${contract_blocker_prompt_count}" \
      "inferred_blocker_count=${contract_blocker_inferred_count}" \
      "commit_mode=$(read_state "done_contract_commit_mode")" \
      "prompt_surfaces=$(read_state "done_contract_prompt_surfaces")" \
      "test_expectation=$(read_state "done_contract_test_expectation")" \
      "inferred_rules=$(read_state "inferred_contract_rules")"
    contract_recovery="$(format_gate_recovery_line "finish the missing surface(s) — items tagged with (R1/R2/R3a/R3b/R4/R5) were inferred from your edits and are silent misses unless addressed. If the repo genuinely cannot support one of them, name that constraint explicitly in your wrap before stopping. For explicit commits, create the commit now or explain why a commit is impossible in this repo.")"
    # v1.34.1+ (P-002): tighter delivery-contract block; the
    # contract_blockers list already names what's missing.
    emit_stop_block "[Delivery-contract gate] work drifting from prompt-stated contract and/or surfaces inferred from edits.
Remaining before Stop:
- ${contract_blockers//$'\n'/$'\n- '}${contract_recovery}"
    exit 0
  fi

  # --- Final-closure gate (user-facing auditability) ---
  #
  # Once the work itself is clean, the final response must let the user
  # audit what changed, how it was verified, and what remains without a
  # follow-up interrogation. This gate is intentionally late: it only
  # runs after the substantive quality checks above have passed.
  closure_edited_count=0
  closure_edited_log="$(session_file "edited_files.log")"
  if [[ -f "${closure_edited_log}" ]]; then
    closure_edited_count="$(sort -u "${closure_edited_log}" | wc -l | tr -d '[:space:]')"
  fi
  [[ "${closure_edited_count}" =~ ^[0-9]+$ ]] || closure_edited_count=0

  closure_dispatch_count="$(read_state "subagent_dispatch_count")"
  [[ "${closure_dispatch_count}" =~ ^[0-9]+$ ]] || closure_dispatch_count=0

  closure_deferred_scope_count="$(read_scope_count_by_status "deferred")"
  [[ "${closure_deferred_scope_count}" =~ ^[0-9]+$ ]] || closure_deferred_scope_count=0
  closure_deferred_finding_count="$(read_findings_count_by_status "deferred")"
  [[ "${closure_deferred_finding_count}" =~ ^[0-9]+$ ]] || closure_deferred_finding_count=0

  closure_needs_risks=0
  if [[ "${closure_deferred_scope_count}" -gt 0 || "${closure_deferred_finding_count}" -gt 0 ]]; then
    closure_needs_risks=1
  fi

  closure_structured_required=0
  if [[ "${closure_edited_count}" -ge 2 || "${closure_dispatch_count}" -ge 1 || "${closure_needs_risks}" -eq 1 ]]; then
    closure_structured_required=1
  fi

  closure_has_changed=0
  has_closeout_label changed "${last_assistant_message}" && closure_has_changed=1
  closure_has_verification=0
  has_closeout_label verification "${last_assistant_message}" && closure_has_verification=1
  closure_has_risks=0
  has_closeout_label risks "${last_assistant_message}" && closure_has_risks=1
  closure_has_next=0
  has_closeout_label next "${last_assistant_message}" && closure_has_next=1

  last_verify_cmd="$(read_state "last_verify_cmd")"
  last_verify_method="$(read_state "last_verify_method")"
  closure_verify_cmd_missing=0
  if [[ -n "${last_verify_cmd}" && "${last_verify_method}" != mcp_* ]]; then
    if [[ "${last_assistant_message}" != *"${last_verify_cmd}"* ]]; then
      closure_verify_cmd_missing=1
    fi
  fi

  closure_structured_ok=0
  if [[ "${closure_has_changed}" -eq 1 ]] \
    && [[ "${closure_has_verification}" -eq 1 ]] \
    && [[ "${closure_has_next}" -eq 1 ]] \
    && [[ "${closure_verify_cmd_missing}" -eq 0 ]] \
    && { [[ "${closure_needs_risks}" -eq 0 ]] || [[ "${closure_has_risks}" -eq 1 ]]; }; then
    closure_structured_ok=1
  fi

  closure_compact_ok=0
  if has_closeout_signal delivery "${last_assistant_message}" \
    && has_closeout_signal verification "${last_assistant_message}" \
    && [[ "${closure_verify_cmd_missing}" -eq 0 ]] \
    && { [[ "${closure_needs_risks}" -eq 0 ]] || has_closeout_signal risks "${last_assistant_message}"; }; then
    closure_compact_ok=1
  fi

  if [[ "${closure_structured_required}" -eq 1 && "${closure_structured_ok}" -ne 1 ]] \
    || [[ "${closure_structured_required}" -eq 0 && "${closure_structured_ok}" -ne 1 && "${closure_compact_ok}" -ne 1 ]]; then
    closure_missing=""
    if [[ "${closure_has_changed}" -ne 1 ]]; then
      closure_missing="${closure_missing:+${closure_missing}, }\`Changed\`/\`Shipped\`"
    fi
    if [[ "${closure_has_verification}" -ne 1 ]]; then
      closure_missing="${closure_missing:+${closure_missing}, }\`Verification\`"
    elif [[ "${closure_verify_cmd_missing}" -eq 1 ]]; then
      closure_missing="${closure_missing:+${closure_missing}, }\`Verification\` must name \`${last_verify_cmd}\`"
    fi
    if [[ "${closure_needs_risks}" -eq 1 && "${closure_has_risks}" -ne 1 ]]; then
      closure_missing="${closure_missing:+${closure_missing}, }\`Risks\`"
    fi
    if [[ "${closure_structured_required}" -eq 1 && "${closure_has_next}" -ne 1 ]]; then
      closure_missing="${closure_missing:+${closure_missing}, }\`Next\`"
    fi
    [[ -n "${closure_missing}" ]] || closure_missing="an audit-ready closeout"

    record_gate_event "final-closure" "block" \
      "structured_required=${closure_structured_required}" \
      "missing_changed=$((closure_has_changed == 1 ? 0 : 1))" \
      "missing_verification=$((closure_has_verification == 1 ? 0 : 1))" \
      "missing_verify_cmd=${closure_verify_cmd_missing}" \
      "missing_risks=$((closure_needs_risks == 1 && closure_has_risks != 1 ? 1 : 0))" \
      "missing_next=$((closure_structured_required == 1 && closure_has_next != 1 ? 1 : 0))" \
      "deferred_scope_count=${closure_deferred_scope_count}" \
      "deferred_finding_count=${closure_deferred_finding_count}"
    closure_recovery="$(format_gate_recovery_line "restate the final wrap using \`**Changed.**\` (or \`**Shipped.**\`), \`**Verification.**\`, and \`**Next.**\`. Name the exact verification command when one ran. If anything was deferred, add \`**Risks.**\` and state the WHY. If no further action is queued, \`**Next.** Done.\` is enough.")"
    # v1.34.1+ (P-002): tighter final-closure block.
    emit_stop_block "[Final-closure gate] work is clean but the final response isn't audit-ready.
Missing: ${closure_missing}.${closure_recovery}"
    exit 0
  fi

  # Record session outcome for cross-session analytics. "completed" means
  # all quality gates were satisfied — the harness's strongest signal.
  # Uses locked write for consistency with the exhaustion paths.
  with_state_lock write_state "session_outcome" "completed"
  # Remove fast-path sentinel; workflow_mode in session_state.json is
  # intentionally preserved so the prompt-intent-router's sticky gate
  # continues injecting specialist routing for the rest of this session.
  rm -f "${STATE_ROOT}/.ulw_active"
  log_hook "stop-guard" "pass: all gates satisfied"
  exit 0
fi

if [[ "${guard_blocks}" -ge 3 ]]; then
  scorecard="$(build_quality_scorecard)"
  with_state_lock_batch \
    "guard_exhausted" "$(now_epoch)" \
    "guard_exhausted_detail" "review=${missing_review},verify=${missing_verify},verify_failed=${verify_failed},unremediated=${review_unremediated},low_confidence=${verify_low_confidence}" \
    "session_outcome" "exhausted"
  log_hook "stop-guard" "exhausted after 3 blocks: review=${missing_review} verify=${missing_verify} failed=${verify_failed} unremediated=${review_unremediated} low_conf=${verify_low_confidence}"

  case "${OMC_GUARD_EXHAUSTION_MODE}" in
    block)
      # Never release — keep blocking with scorecard
      emit_stop_block "[Quality gate · BLOCK MODE] Guard exhaustion reached but block mode prevents release. QUALITY SCORECARD:\n${scorecard}\nAddress the remaining items or switch to guard_exhaustion_mode=scorecard in oh-my-claude.conf."
      exit 0
      ;;
    scorecard)
      # Release but inject scorecard as context
      # v1.27.0 (F-024): see review-coverage scorecard above for the
      # rationale behind the actionable footer. Same pattern: name the
      # concrete next-step shapes instead of "note any gaps".
      emit_scorecard_stop_context \
        "QUALITY SCORECARD (guard exhausted after 3 blocks):" \
        "**FOR YOU:** The quality gate released without full completion — work shipped without all gates satisfied. The model's next response will summarize what shipped vs. what's missing so you can audit. **FOR MODEL:** Recovery options: (a) restate WHICH gates released without satisfaction so the user can audit them; (b) run a fresh quality-reviewer pass on the diff and address the findings (one short pass usually converts scorecard release into clean release); (c) run the project test suite (\`/ulw-status\` shows the detected command) and commit on green; (d) if the work is genuinely paused on user input, run /ulw-pause <reason> instead of letting the gate scorecard-release." \
        "${scorecard}"
      exit 0
      ;;
    *)
      # silent (default legacy behavior) — silent release
      rm -f "${STATE_ROOT}/.ulw_active"
      exit 0
      ;;
  esac
fi

write_state "stop_guard_blocks" "$((guard_blocks + 1))"

# --- Block-message construction ---
#
# Block 1 emits the full verbose "FIRST self-assess" text — this is the
# one pass every complex task goes through and the self-assessment prompt
# demonstrably helps agents catch completeness gaps on the first round.
#
# Blocks 2–3 switch to a concise form that names only the missing items
# and the next action, reducing the summary-inflation pressure that long
# repeat-message boilerplate produced in pre-fix sessions. The concise
# form still contains the literal tokens `validation` and
# `quality-reviewer` / `editor-critic` so downstream tests and agent
# routing keep working.

# Route the "quality reviewer" label based on whether the edits were
# code (quality-reviewer) or doc-only (editor-critic).
if [[ "${need_doc_review}" -eq 1 && "${need_code_review}" -eq 0 ]]; then
  review_target_label="editor-critic"
  review_domain_verbose="writing"
else
  review_target_label="quality-reviewer"
  review_domain_verbose="coding"
fi

verify_action=""
review_action=""

# If we know the project test command, name it in the verification action.
# Fall back to on-demand detection when state is empty — this happens on
# the first missing_verify block, before any verification has run to
# populate `project_test_cmd` in record-verification.sh.
project_test_cmd="$(read_state "project_test_cmd")"
if [[ -z "${project_test_cmd}" ]]; then
  project_test_cmd="$(detect_project_test_command "." 2>/dev/null || true)"
  if [[ -n "${project_test_cmd}" ]]; then
    write_state "project_test_cmd" "${project_test_cmd}"
  fi
fi

if [[ "${missing_verify}" -eq 1 ]]; then
  if [[ -n "${project_test_cmd}" ]]; then
    verify_action="run \`${project_test_cmd}\` (detected project test command) to validate"
  else
    verify_action="run the smallest meaningful validation available"
  fi
elif [[ "${verify_failed}" -eq 1 ]]; then
  last_verify_cmd="$(read_state "last_verify_cmd")"
  if [[ -n "${last_verify_cmd}" ]]; then
    verify_action="the last verification (\`${last_verify_cmd}\`) failed — fix the underlying issues and re-run"
  else
    verify_action="the last verification command failed — fix the underlying issues and re-run verification"
  fi
elif [[ "${verify_low_confidence}" -eq 1 ]]; then
  last_verify_cmd="$(read_state "last_verify_cmd")"
  if [[ -n "${project_test_cmd}" ]]; then
    verify_action="the last verification (\`${last_verify_cmd:-unknown}\`) had low confidence (${last_verify_confidence}/100, threshold: ${OMC_VERIFY_CONFIDENCE_THRESHOLD}) — run the project test suite (\`${project_test_cmd}\`) for proper validation"
  else
    verify_action="the last verification had low confidence (${last_verify_confidence}/100) — run a more comprehensive test command (e.g., the project's test suite) instead of a single-file check"
  fi
fi

if [[ "${guard_blocks}" -eq 0 ]]; then
  # Block 1: full verbose text. Preserve the existing wording exactly so
  # existing test assertions (seq-D "validation", "quality-reviewer") and
  # agent routing keep working.
  if [[ "${missing_review}" -eq 1 ]]; then
    if [[ "${task_domain}" == "writing" || "${task_domain}" == "research" || "${task_domain}" == "operations" || "${task_domain}" == "general" ]]; then
      review_action="FIRST self-assess: enumerate every component of the original request and mark each as delivered, partial, or missing — continue implementing anything not fully delivered. THEN delegate to editor-critic or another relevant reviewer and address any high-signal findings — the reviewer must evaluate not just quality issues but completeness: does this deliver everything the user asked for?"
    else
      review_action="FIRST self-assess: enumerate every component of the original request and mark each as delivered, partial, or missing — continue implementing anything not fully delivered. THEN delegate to ${review_target_label} and address its highest-signal findings — the reviewer must evaluate not just bugs but completeness: does the implementation cover the full scope of the original task?"
    fi
  elif [[ "${review_unremediated}" -eq 1 ]]; then
    review_action="the reviewer flagged issues that were not addressed — fix them or explain why they do not apply, then re-evaluate whether the deliverable is complete"
  fi

  if [[ -n "${verify_action}" && -n "${review_action}" ]]; then
    reason="${reason} Continue working: ${verify_action}, then ${review_action}, and only then stop."
  elif [[ -n "${verify_action}" ]]; then
    reason="${reason} Continue working: ${verify_action} before stopping. If reliable automation is impossible, explain the exact blocker and residual risk."
  elif [[ -n "${review_action}" ]]; then
    reason="${reason} Continue working: ${review_action}, and only then stop."
  fi

  reason="${reason} After completing these steps, restate your key deliverable summary at the end of your response."
else
  # Blocks 2+: concise form. Lists what's still missing and the single
  # next action, without the summary-reinflating self-assess boilerplate.
  #
  # UX win (#3): name the detected project_test_cmd in concise messages
  # too, not just in the verbose block-1 path. Without this, a user who
  # ignored the block-1 hint sees increasingly vague prompts — the
  # opposite of what they need. The exact-command hint is the one
  # concrete action that unblocks them, so we repeat it every block.
  missing_items=""
  if [[ "${missing_review}" -eq 1 ]]; then
    missing_items="${missing_items:+${missing_items}, }review (${review_target_label})"
  fi
  if [[ "${review_unremediated}" -eq 1 ]]; then
    missing_items="${missing_items:+${missing_items}, }unremediated findings"
  fi
  if [[ "${missing_verify}" -eq 1 ]]; then
    missing_items="${missing_items:+${missing_items}, }validation"
  fi
  if [[ "${verify_failed}" -eq 1 ]]; then
    missing_items="${missing_items:+${missing_items}, }failed validation (fix and re-run)"
  fi
  if [[ "${verify_low_confidence}" -eq 1 ]]; then
    if [[ -n "${project_test_cmd}" ]]; then
      missing_items="${missing_items:+${missing_items}, }low-confidence validation (run \`${project_test_cmd}\`)"
    else
      missing_items="${missing_items:+${missing_items}, }low-confidence validation (run project test suite)"
    fi
  fi

  next_action=""
  if [[ "${missing_verify}" -eq 1 ]]; then
    if [[ -n "${project_test_cmd}" ]]; then
      next_action="run \`${project_test_cmd}\` (detected project test command), then delegate ${review_target_label}"
    else
      next_action="run the smallest meaningful validation, then delegate ${review_target_label}"
    fi
  elif [[ "${verify_failed}" -eq 1 ]]; then
    next_action="fix the failing tests and re-run validation"
  elif [[ "${verify_low_confidence}" -eq 1 ]]; then
    if [[ -n "${project_test_cmd}" ]]; then
      next_action="run \`${project_test_cmd}\` (detected project test command) for proper validation (current confidence: ${last_verify_confidence}/100)"
    else
      next_action="run the project's test suite for proper validation (current confidence: ${last_verify_confidence}/100)"
    fi
  elif [[ "${missing_review}" -eq 1 ]]; then
    next_action="delegate ${review_target_label}"
  elif [[ "${review_unremediated}" -eq 1 ]]; then
    next_action="address the flagged findings or explain why they do not apply"
  fi

  reason="${reason} Still missing: ${missing_items}.$(format_gate_recovery_line "${next_action}")"

  if [[ "${guard_blocks}" -ge 2 ]]; then
    # Penultimate block: add progress scorecard for visibility
    progress_score="$(compute_progress_score)"
    reason="${reason} NOTE: this is the final guard block — the next stop attempt will be allowed regardless of quality gate status. Progress score: ${progress_score}/100."
  fi
fi

record_gate_event "quality" "block" \
  "block_count=$((guard_blocks + 1))" "block_cap=3" \
  "missing_review=${missing_review}" \
  "missing_verify=${missing_verify}" \
  "verify_failed=${verify_failed}" \
  "verify_low_confidence=${verify_low_confidence}" \
  "review_unremediated=${review_unremediated}"
emit_stop_block "${reason}"
