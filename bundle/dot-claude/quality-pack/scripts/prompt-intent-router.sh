#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${HOME}/.claude/skills/autowork/scripts/common.sh"

SESSION_ID="$(json_get '.session_id')"
PROMPT_TEXT="$(json_get '.prompt')"

if [[ -z "${SESSION_ID}" || -z "${PROMPT_TEXT}" ]]; then
  log_hook "prompt-intent-router" "skip: no session or prompt"
  exit 0
fi

ensure_session_dir
sweep_stale_sessions

previous_objective="$(read_state "current_objective")"
previous_domain="$(read_state "task_domain")"
previous_last_assistant="$(read_state "last_assistant_message")"

# Gap 2 — post-compact intent bias. When the very first UserPromptSubmit
# fires after a PostCompact hook, we treat the previous objective as
# canonical unless the user's prompt is a clearly unrelated execution task.
# Rationale: the native compact summary + injected handoff can make the
# main thread misread short ambiguous prompts ("continue", "next", "status")
# as fresh work. The flag decays after one prompt, or after 15 minutes of
# staleness, whichever comes first.
post_compact_bias=0
just_compacted_value="$(read_state "just_compacted")"
just_compacted_ts_value="$(read_state "just_compacted_ts")"
if [[ "${just_compacted_value}" == "1" ]] && [[ -n "${just_compacted_ts_value}" ]]; then
  compact_age=$(( $(now_epoch) - just_compacted_ts_value ))
  if (( compact_age >= 0 )) && (( compact_age < 900 )); then
    post_compact_bias=1
    log_hook "prompt-intent-router" "post-compact bias active (age=${compact_age}s)"
  fi
  # Always clear on first read — single-use flag.
  write_state_batch "just_compacted" "" "just_compacted_ts" ""
fi

TASK_INTENT="$(classify_task_intent "${PROMPT_TEXT}")"
PROMPT_TS="$(now_epoch)"
EXEMPLIFYING_SCOPE_DETECTED=0
if is_execution_intent_value "${TASK_INTENT}" && is_exemplifying_request "${PROMPT_TEXT}"; then
  EXEMPLIFYING_SCOPE_DETECTED=1
fi

# Classifier telemetry — capture this turn's classification and let the
# misfire detector judge the PRIOR turn based on accumulated evidence.
# Detection must happen before writes that reset pretool_intent_blocks or
# advisory_guard_blocks so the snapshot reflects the window just closed.
current_pretool_blocks="$(read_state "pretool_intent_blocks" 2>/dev/null || true)"
current_pretool_blocks="${current_pretool_blocks:-0}"
detect_classifier_misfire "${PROMPT_TEXT}" "${current_pretool_blocks}" || true

write_state_batch \
  "stop_guard_blocks" "0" \
  "session_handoff_blocks" "0" \
  "advisory_guard_blocks" "0" \
  "last_advisory_verify_ts" "" \
  "task_intent" "${TASK_INTENT}" \
  "last_user_prompt" "${PROMPT_TEXT}" \
  "last_user_prompt_ts" "${PROMPT_TS}" \
  "stall_counter" "0" \
  "ulw_pause_active" ""
append_limited_state \
  "recent_prompts.jsonl" \
  "$(jq -nc --arg ts "${PROMPT_TS}" --arg text "${PROMPT_TEXT}" '{ts:$ts,text:$text}')" \
  "12"

if [[ "${OMC_EXEMPLIFYING_SCOPE_GATE:-on}" == "on" ]]; then
  if [[ "${EXEMPLIFYING_SCOPE_DETECTED}" -eq 1 ]]; then
    write_state_batch \
      "exemplifying_scope_required" "1" \
      "exemplifying_scope_prompt_ts" "${PROMPT_TS}" \
      "exemplifying_scope_prompt_preview" "$(truncate_chars 240 "${PROMPT_TEXT}")" \
      "exemplifying_scope_blocks" "0" \
      "exemplifying_scope_checklist_ts" "" \
      "exemplifying_scope_pending_count" "" \
      "exemplifying_scope_satisfied_ts" ""
  elif is_execution_intent_value "${TASK_INTENT}"; then
    write_state_batch \
      "exemplifying_scope_required" "" \
      "exemplifying_scope_prompt_ts" "" \
      "exemplifying_scope_prompt_preview" "" \
      "exemplifying_scope_blocks" "" \
      "exemplifying_scope_checklist_ts" "" \
      "exemplifying_scope_pending_count" "" \
      "exemplifying_scope_satisfied_ts" ""
  fi
fi

if ! is_maintenance_prompt "${PROMPT_TEXT}"; then
  normalized_objective="$(normalize_task_prompt "${PROMPT_TEXT}")"
  if is_continuation_request "${PROMPT_TEXT}" && [[ -n "${previous_objective}" ]]; then
    write_state "current_objective" "${previous_objective}"
  elif [[ "${TASK_INTENT}" == "advisory" || "${TASK_INTENT}" == "session_management" || "${TASK_INTENT}" == "checkpoint" ]] \
    && [[ -n "${previous_objective}" ]]; then
    write_state "current_objective" "${previous_objective}"
  elif [[ "${post_compact_bias}" -eq 1 ]] && [[ -n "${previous_objective}" ]]; then
    # Gap 2 — post-compact bias: if the user did not clearly start a new
    # execution task, keep the preserved objective from before the compact.
    # "Clearly new" is detected by: an imperative/action prompt that does
    # not match a continuation keyword. Advisory/meta prompts are already
    # handled above, and continuation prompts are handled one branch up,
    # so landing here means TASK_INTENT=execution. We still defer to the
    # preserved objective unless the normalized body is substantial and
    # obviously a fresh task (length > 40 chars AND not starting with a
    # reference to the preserved work).
    if [[ -z "${normalized_objective}" ]] || [[ "${#normalized_objective}" -lt 40 ]]; then
      write_state "current_objective" "${previous_objective}"
      log_hook "prompt-intent-router" "post-compact bias: preserved objective (short/empty prompt)"
    else
      write_state "current_objective" "${normalized_objective}"
    fi
  elif [[ -n "${normalized_objective}" ]]; then
    write_state "current_objective" "${normalized_objective}"
  else
    write_state "current_objective" "${PROMPT_TEXT}"
  fi
fi

# Gap 4c — clear review_pending_at_compact after the first post-compact
# prompt. The session-start-compact-handoff.sh has already injected the
# "MUST run reviewer" directive at this point, so the flag has served its
# purpose. Leaving it set would re-inject on every subsequent prompt.
# The stop-guard still enforces the underlying review requirement via its
# own edit/review-clock comparison — this flag only controlled the
# compact-boundary directive injection.
if [[ "${post_compact_bias}" -eq 1 ]]; then
  existing_review_flag="$(read_state "review_pending_at_compact")"
  if [[ -n "${existing_review_flag}" ]]; then
    write_state "review_pending_at_compact" ""
  fi
fi

if [[ "${TASK_INTENT}" == "advisory" || "${TASK_INTENT}" == "session_management" || "${TASK_INTENT}" == "checkpoint" ]]; then
  normalized_meta_request="$(trim_whitespace "$(normalize_task_prompt "${PROMPT_TEXT}")")"
  if [[ -n "${normalized_meta_request}" ]]; then
    write_state "last_meta_request" "${normalized_meta_request}"
  else
    write_state "last_meta_request" "${PROMPT_TEXT}"
  fi
fi

context_parts=()

render_prior_specialist_summaries() {
  local summaries_file
  summaries_file="$(session_file "subagent_summaries.jsonl")"

  if [[ ! -f "${summaries_file}" ]]; then
    return
  fi

  tail -n 6 "${summaries_file}" | while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    jq -r 'select(.agent_type and .message) |
      "- \(.agent_type): \(.message | gsub("[\\r\\n]+"; " ") | .[:400])"
    ' <<<"${line}" 2>/dev/null || true
  done
}

if is_ulw_trigger "${PROMPT_TEXT}" \
   || [[ "$(read_state 'workflow_mode')" == "ultrawork" ]]; then
  continuation_prompt=0
  continuation_directive=""
  advisory_prompt=0
  session_management_prompt=0
  checkpoint_prompt=0

  # Detect project profile for domain scoring boost
  _project_profile="$(get_project_profile 2>/dev/null || true)"

  if is_continuation_request "${PROMPT_TEXT}" && [[ -n "${previous_objective}" ]]; then
    continuation_prompt=1
    continuation_directive="$(extract_continuation_directive "${PROMPT_TEXT}")"
    TASK_DOMAIN="${previous_domain:-$(infer_domain "${previous_objective}" "${_project_profile}")}"
    write_state "current_objective" "${previous_objective}"
  elif [[ "${TASK_INTENT}" == "session_management" ]]; then
    session_management_prompt=1
    TASK_DOMAIN="${previous_domain:-$(infer_domain "${PROMPT_TEXT}" "${_project_profile}")}"
  elif [[ "${TASK_INTENT}" == "advisory" ]]; then
    advisory_prompt=1
    TASK_DOMAIN="${previous_domain:-$(infer_domain "${PROMPT_TEXT}" "${_project_profile}")}"
  elif [[ "${TASK_INTENT}" == "checkpoint" ]]; then
    checkpoint_prompt=1
    TASK_DOMAIN="${previous_domain:-$(infer_domain "${PROMPT_TEXT}" "${_project_profile}")}"
  else
    TASK_DOMAIN="$(infer_domain "${PROMPT_TEXT}" "${_project_profile}")"
  fi

  write_state "workflow_mode" "ultrawork"
  write_state "task_domain" "${TASK_DOMAIN}"

  # Record session start time (only on first ULW activation, not every prompt)
  existing_start_ts="$(read_state "session_start_ts")"
  if [[ -z "${existing_start_ts}" ]]; then
    write_state "session_start_ts" "$(now_epoch)"
  fi

  # Record the working directory at first ULW activation so
  # `discover_latest_session` (used by command-line scripts that lack
  # hook JSON) can prefer the session whose cwd matches the current
  # process, instead of grabbing the newest-by-mtime session — which
  # leaks across concurrent projects when two sessions race on touch.
  existing_cwd="$(read_state "cwd")"
  if [[ -z "${existing_cwd}" ]]; then
    SESSION_CWD="$(json_get '.cwd')"
    if [[ -n "${SESSION_CWD}" ]]; then
      write_state "cwd" "${SESSION_CWD}"
    fi
  fi

  # Classifier telemetry — now that TASK_DOMAIN is known, record the row.
  # Outside-ULW sessions also skip this (no state bookkeeping there).
  record_classifier_telemetry \
    "${TASK_INTENT}" \
    "${TASK_DOMAIN}" \
    "${PROMPT_TEXT}" \
    "${current_pretool_blocks}" || true

  # Sentinel for fast-path exit in PostToolUse hooks (zero-cost check)
  touch "${STATE_ROOT}/.ulw_active"

  log_hook "prompt-intent-router" "ulw=on domain=${TASK_DOMAIN} intent=${TASK_INTENT}"

  # Display form of TASK_INTENT: state-layer uses underscores (session_management),
  # but the user-visible classification line reads better with hyphens. Normalize
  # once here so all branches render consistently.
  display_intent="${TASK_INTENT//_/-}"

  if [[ "${continuation_prompt}" -eq 1 ]]; then
    context_parts+=("Ultrawork continuation mode is active for this session. Continue the prior task instead of treating the literal word 'continue' or 'resume' as a new objective. In your first user-facing response, start with the bold phrase **Ultrawork continuation active.** then briefly state what is already done, what remains, and the next concrete action. Reuse finished work, preserve the existing task domain, and only re-dispatch branches that were interrupted or are still missing.")
    context_parts+=("Surface the classification after the opener — e.g., '**Domain:** ${TASK_DOMAIN} | **Intent:** ${display_intent}' — so the user can verify routing is correct.")
    context_parts+=("Preserved objective: ${previous_objective}")

    if [[ -n "${previous_last_assistant}" ]]; then
      context_parts+=("Last recorded assistant state before the interruption: $(truncate_chars 700 "${previous_last_assistant}")")
    fi

    specialist_context="$(render_prior_specialist_summaries)"
    if [[ -n "${specialist_context}" ]]; then
      context_parts+=("Recent specialist conclusions:\n${specialist_context}")
    fi

    if [[ -n "${continuation_directive}" ]]; then
      context_parts+=("Additional continuation directive from the user: ${continuation_directive}")
    fi

    # Phase 8 resume hint: when a continuation prompt arrives in a session
    # with a non-empty wave plan AND pending findings, inject the resume
    # protocol. Council-detection-only injection (line 464+) misses this
    # case because continuation prompts may not match council-evaluation
    # patterns even when the prior wave plan is real.
    _wave_status_line="$("${HOME}/.claude/skills/autowork/scripts/record-finding-list.sh" status-line 2>/dev/null || true)"
    if [[ -n "${_wave_status_line}" ]] && [[ "${_wave_status_line}" != *"no plan yet"* ]] \
       && [[ "${_wave_status_line}" == *pending* || "${_wave_status_line}" == *in-progress* ]]; then
      context_parts+=("**Phase 8 wave plan detected** in this session: ${_wave_status_line}. Resume protocol: do NOT call \`record-finding-list.sh init\` (the existing plan would be clobbered). Run \`record-finding-list.sh counts\` and \`show\` to see where execution stands, identify the in-progress wave, and re-enter at the per-wave cycle (planner → impl → quality-reviewer → excellence-reviewer → verify → commit) for the next pending wave. Findings already marked shipped are done; pending findings still need work.")
    fi

    # Wave 2 resume hint: when a continuation prompt arrives AND there is
    # a claimable resume_request.json on disk for this cwd, inject a
    # directive recommending /ulw-resume. Distinct from the SessionStart
    # resume-hint hook (Wave 1) which fires once per session — this
    # directive covers the case where the user typed an unrelated prompt
    # at SessionStart, dismissed/missed the hint, and later says
    # "continue". To avoid re-injecting on every continuation prompt
    # for the same artifact in the same session (excellence-review
    # Finding 5: hot path), the directive is suppressed when either
    # (a) the SessionStart hint already mentioned this artifact in this
    # session — `resume_hint_emitted_<sid>` is set — or (b) the router
    # itself already injected the directive once — `resume_directive_<sid>`.
    # The artifact is automatically excluded by find_claimable_resume_requests
    # if the user has dismissed it via /ulw-resume --dismiss.
    if is_stop_failure_capture_enabled \
        && [[ -f "${HOME}/.claude/skills/ulw-resume/SKILL.md" ]]; then
      _resume_candidate="$(find_claimable_resume_requests 2>/dev/null \
        | jq -r --arg cwd "${PWD}" 'select(.cwd == $cwd) | .session_id' 2>/dev/null \
        | head -1)"
      if [[ -n "${_resume_candidate}" ]] \
         && validate_session_id "${_resume_candidate}"; then
        _hint_state_key="resume_hint_emitted_${_resume_candidate}"
        _directive_state_key="resume_directive_${_resume_candidate}"
        _hint_already_shown="$(read_state "${_hint_state_key}")"
        _directive_already_shown="$(read_state "${_directive_state_key}")"
        if [[ "${_hint_already_shown}" != "1" ]] && [[ "${_directive_already_shown}" != "1" ]]; then
          context_parts+=("**Pending resume request for this cwd** (origin_session=${_resume_candidate}). A prior /ulw task in this directory was killed by a Claude Code StopFailure; the artifact is unclaimed. Before continuing, invoke the \`/ulw-resume\` skill to atomically claim the artifact and replay the original objective verbatim — that is the resume path that preserves exhaustive-authorization markers, council triggers, and specific constraints. If the user's continuation explicitly references different work than the artifact's recorded objective, run \`/ulw-resume --dismiss\` to silence the hint, or ignore this directive and proceed (the dismiss verb prevents re-injection on subsequent continuation prompts in this session).")
          write_state "${_directive_state_key}" "1"
        fi
      fi
    fi
  elif [[ "${session_management_prompt}" -eq 1 ]]; then
    context_parts+=("Ultrawork intent gate classified this prompt as session-management advice, not execution. Answer the user's question directly. Preserve the active objective instead of treating this prompt as a new task. Do not start implementing more work unless the user explicitly asks you to continue now. If you recommend a fresh session, checkpoint, or pause, explain why cleanly and stop without triggering deferral-style execution pressure.")
    context_parts+=("Lead your response with the classification line — e.g., '**Domain:** ${TASK_DOMAIN} | **Intent:** ${display_intent}' — before answering, so the user can verify routing is correct.")
    if [[ -n "${previous_objective}" ]]; then
      context_parts+=("Preserved active objective in the background: ${previous_objective}")
    fi
    if [[ -n "${previous_domain}" ]]; then
      context_parts+=("Underlying active task domain: ${previous_domain}")
    fi
  elif [[ "${advisory_prompt}" -eq 1 ]]; then
    context_parts+=("Ultrawork intent gate classified this prompt as advisory or decision support, not direct execution. Answer the question directly, use the current task state as context if relevant, and do not force implementation unless the user explicitly asks for it.")
    context_parts+=("Lead your response with the classification line — e.g., '**Domain:** ${TASK_DOMAIN} | **Intent:** ${display_intent}' — before answering, so the user can verify routing is correct.")
    if [[ -n "${previous_objective}" ]]; then
      context_parts+=("Preserved active objective in the background: ${previous_objective}")
    fi
    if [[ -n "${previous_domain}" ]]; then
      context_parts+=("Underlying active task domain: ${previous_domain}")
    fi
    # Note: ADVISORY OVER CODE guidance is deferred — it will be injected below
    # only if council evaluation is NOT detected (council dispatch is a superset
    # of advisory's "inspect before recommending" requirement).
  elif [[ "${checkpoint_prompt}" -eq 1 ]]; then
    context_parts+=("Ultrawork intent gate classified this prompt as a checkpoint or pause request. Preserve the active objective, provide a sharp checkpoint, state what is done and what remains, and stop cleanly without forcing full completion in this turn.")
    context_parts+=("Lead your response with the classification line — e.g., '**Domain:** ${TASK_DOMAIN} | **Intent:** ${display_intent}' — before the checkpoint, so the user can verify routing is correct.")
    if [[ -n "${previous_objective}" ]]; then
      context_parts+=("Preserved active objective in the background: ${previous_objective}")
    fi
  else
    context_parts+=("Ultrawork mode is active for this session. In your first user-facing response, start with the bold phrase **Ultrawork mode active.** as the opening line for visual distinction. Use the strongest specialist path available, keep momentum high, and do not stop early. Do not segment unfinished work into 'wave 1 done, wave 2 next' or 'ready for a new session' unless the user explicitly asked for a checkpoint.")
    context_parts+=("Detected intent: ${display_intent}. Detected domain: ${TASK_DOMAIN}. Surface the classification right after the opener — '**Domain:** ${TASK_DOMAIN} | **Intent:** ${display_intent}' — followed by the first action you will take, so the user can verify routing is correct. If the user corrects the classification, adjust immediately.")

    # --- Bias-defense directives (v1.19.0, default-off) ---
    #
    # Two opt-in injections that target the bias-blindness gap (model
    # risks confidently solving the wrong problem because the prompt
    # was short or product-shaped and the model never paused to verify
    # intent). Both fire only on fresh execution prompts — the four
    # earlier branches (continuation, session-management, advisory,
    # checkpoint) skip this block entirely.
    #
    # Mutually exclusive on the same turn: prometheus-suggest is the
    # heavier intervention (recommends an interview-first sub-agent),
    # so when it fires the intent-verify is suppressed to avoid
    # double-friction. Both are conf-gated and default OFF; a user
    # who flips one or both gets the directive injected here, and the
    # model then has discretion to skip when the goal is unambiguous
    # in context.
    _bias_directive_emitted=0
    if [[ "${OMC_PROMETHEUS_SUGGEST:-off}" == "on" ]] \
        && is_product_shaped_request "${PROMPT_TEXT}" \
        && is_ambiguous_execution_request "${PROMPT_TEXT}"; then
      context_parts+=("AMBIGUOUS PRODUCT-SHAPED PROMPT: this request looks short and product-shaped (build/create/design + app/dashboard/feature/onboarding/etc.) without a specific code anchor. Before editing, consider running /prometheus to interview-first scope the goal, audience, success criteria, and constraints. If the scope is already clear from prior context or you have already clarified with the user, proceed. The directive exists to catch the failure mode where the model commits to a particular product shape on incomplete information and ships the wrong thing.")
      _bias_directive_emitted=1
      log_hook "prompt-intent-router" "bias-defense: prometheus-suggest fired"
      record_gate_event "bias-defense" "directive_fired" \
        "directive=prometheus-suggest"
    fi
    if [[ "${OMC_INTENT_VERIFY_DIRECTIVE:-off}" == "on" ]] \
        && [[ "${_bias_directive_emitted}" -eq 0 ]] \
        && is_ambiguous_execution_request "${PROMPT_TEXT}"; then
      context_parts+=("INTENT VERIFICATION: this prompt is short and unanchored (no file path, line ref, function name, or backtick-fenced identifier). Before your first edit, restate the user's goal in 1-2 sentences and ask the user to confirm or correct. If the goal is unambiguous from the prompt or the user has already confirmed in a prior turn, skip the pause and proceed. The directive exists to catch the failure mode where the model confidently solves the wrong problem because the request had multiple plausible interpretations.")
      log_hook "prompt-intent-router" "bias-defense: intent-verify fired"
      record_gate_event "bias-defense" "directive_fired" \
        "directive=intent-verify"
    fi

    # --- Exemplifying-scope widening directive (v1.23.0, default-on) ---
    #
    # Symmetric to the prometheus/intent-verify narrowing directives
    # but fires for the OPPOSITE bias: when the user phrases scope
    # with example markers ("for instance", "e.g.", "such as", "as
    # needed", "like X"), the model historically interpreted the
    # example as the literal scope and dropped the class. This
    # directive flips the default under ULW — when the prompt
    # exemplifies, treat the example as one item from an enumerable
    # class and enumerate siblings.
    #
    # Default ON because the failure mode it defends against was the
    # user's primary v1.22.x complaint ("scope" had become an escape
    # trick). The directive itself is framing; the separate
    # exemplifying_scope_gate flag decides whether Stop enforces the
    # resulting checklist.
    #
    # Fires INDEPENDENTLY of the narrowing directives (no
    # _bias_directive_emitted gating) because narrowing and widening
    # are orthogonal axes — a product-shaped exemplifying prompt could
    # legitimately receive both (clarify the goal interview-first AND
    # treat the named example as class-shaped scope).
    if [[ "${OMC_EXEMPLIFYING_DIRECTIVE:-on}" == "on" ]] \
        && [[ "${EXEMPLIFYING_SCOPE_DETECTED}" -eq 1 ]]; then
      exemplifying_scope_workflow="Before stopping, enumerate the sibling items in the same class (other items a veteran would bundle into the same pass) and address all of them, or explicitly decline each with a one-line concrete WHY."
      if [[ "${OMC_EXEMPLIFYING_SCOPE_GATE:-on}" == "on" ]]; then
        exemplifying_scope_workflow="After initial inspection and before implementation settles, record a checklist with \`~/.claude/skills/autowork/scripts/record-scope-checklist.sh init\` (JSON array of sibling scope items), then mark each item \`shipped\` or \`declined\` with a concrete WHY before stopping; the exemplifying-scope stop gate will block silent drops."
      fi
      context_parts+=("EXEMPLIFYING SCOPE DETECTED: the prompt uses example markers ('for instance' / 'e.g.' / 'i.e.' / 'for example' / 'such as' / 'as needed' / 'as appropriate' / 'similar to' / 'including but not limited to' / 'things like' / 'stuff like' / 'examples include'). Treat the example as ONE item from an enumerable class — the *class* is the scope, not the literal example. ${exemplifying_scope_workflow} Implementing only the literal example and silently dropping the class is **under-interpretation, not restraint** — it is the failure mode \`/ulw\` was created to prevent. Worked example: 'enhance the statusline, for instance adding reset countdown' enumerates as: reset countdown, in-flight indicators (pause/wave/plan markers), stale-data warnings, count surfaces, model-name handling — all live in the same statusline render path and are class items, not new capabilities. See core.md 'Excellence is not gold-plating' Calibration test, **Also keep going** bullet for the same rule. The user's request IS the permission to enumerate the class — do not gate-keep yourself by asking which siblings to include.")
      log_hook "prompt-intent-router" "bias-defense: exemplifying-directive fired"
      record_gate_event "bias-defense" "directive_fired" \
        "directive=exemplifying"
    fi
  fi

  if [[ "${session_management_prompt}" -eq 0 && "${checkpoint_prompt}" -eq 0 ]]; then
    # Project-maturity prior — informational tag biasing advisory framing.
    # Fires once per session (cached) for active modes only. Skipped on
    # session-management and checkpoint prompts since maturity-flavored
    # framing on `/ulw-status` is just noise. The maturity tag changes
    # the implicit default of "what does the user want right now?" — a
    # brand-new prototype gets shipping advice, a polish-saturated
    # project gets strategic / soul / signature advice. Without this
    # signal the harness defaults to engineering pragmatism (ship-
    # readiness) on every project, including ones where that framing is
    # wrong.
    _project_maturity="$(get_project_maturity 2>/dev/null || true)"
    case "${_project_maturity}" in
      polish-saturated)
        context_parts+=("**Project maturity:** polish-saturated — long-running project with deep tests and cross-session memory. The user is not asking for a ship-readiness checklist; they are asking 'what's the next strategic move?'. Bias advisory framing toward soul, signature, voice, negative-space, AI-as-experience, first-five-minutes, and excellence-bar concerns rather than feature-completeness or engineering-pragmatism framings. The ship bar is high — match it. Specifically: when asked open-ended 'what's next' / 'evaluate' / 'review' questions, lead with strategic moves and excellence concerns; only surface ship-readiness items when they are genuine blockers.")
        ;;
      mature)
        context_parts+=("**Project maturity:** mature — established project with substantial test coverage. Bias advisory framing toward balancing new work with regression risk. New behavior must come with tests; refactors should be incremental and well-bounded. Avoid suggestions that imply 'rewrite this' unless the user has already signaled appetite for it.")
        ;;
      shipping)
        context_parts+=("**Project maturity:** shipping — early-to-mid project, beyond prototype but not yet polish-saturated. Standard ship-readiness framing applies; verify before claiming complete. New behavior should come with tests, but don't over-architect.")
        ;;
      prototype)
        context_parts+=("**Project maturity:** prototype — new repo, < 30 commits. Focus on shipping a working slice; do not over-architect or demand exhaustive test coverage for code that may pivot. Suggestions should bias toward concrete forward motion over polish.")
        ;;
      unknown|"")
        :  # No git repo or git unavailable — skip the maturity hint
        ;;
    esac

    case "${TASK_DOMAIN}" in
      coding)
        context_parts+=("Detected likely task domain: coding.
Route by task shape:
- broad or underspecified work → prometheus for interview-first scoping
- non-trivial but specified work → quality-planner to scope explicit and implied requirements
- local repo conventions or APIs unclear → quality-researcher
- library, framework, or external API usage → librarian for official docs and reference implementations (or the context7 MCP when that plugin is installed) to confirm current syntax before writing code that calls it
- risky plan → metis to pressure-test hidden assumptions
- hard debugging or architecture uncertainty → oracle
- backend services, REST/GraphQL APIs, database schemas, migrations, auth, queues, caching, search → backend-api-developer
- infrastructure, CI/CD, Docker, Kubernetes, Terraform, deployment, observability → devops-infrastructure-engineer
- test strategy, coverage gaps, flaky tests, test architecture, fuzzing, performance tests → test-automation-engineer
- features spanning frontend + backend (auth flows, payments, real-time, file upload, search, notifications) → fullstack-feature-builder
- Apple platforms (Swift, SwiftUI, Xcode) → ios-ui-developer (screens & animations), ios-core-engineer (data, networking, lifecycle), ios-deployment-specialist (TestFlight & App Store), ios-ecosystem-integrator (HealthKit, WidgetKit, StoreKit, etc.)
- the framing or paradigm fit feels off — 'is this the right shape of solution?' → abstraction-critic (distinct from metis on plan edge cases and oracle on debugging)
Discipline:
- Make changes incrementally — one logical change, verify it, then proceed.
- Test rigorously after edits — failing to test is the #1 failure mode.
- Before invoking the reviewer, self-assess: enumerate every component of the request and verify each is delivered.
- Run quality-reviewer before stopping. For complex or multi-file tasks, also run excellence-reviewer after defects are addressed for a fresh-eyes completeness and polish evaluation.
- Never write placeholder stubs or sycophantic comments.
- Never call an unfamiliar or version-sensitive library/API from memory — confirm the surface in current docs first.
- When you discover a verified adjacent defect on the same code path with a bounded fix, the Serendipity Rule (core.md) requires fixing it in-session AND logging it via \`~/.claude/skills/autowork/scripts/record-serendipity.sh\` so the rule's effectiveness can be audited. Watch for adjacent defects during edits — that's when the rule is most likely to apply.")
        ;;
      writing)
        context_parts+=("Detected likely task domain: writing. Detect the document type early: formal (paper, report, proposal), informal (email, blog, memo), creative (essay, narrative), technical (docs, API reference), or professional (cover letter, SOP, statement). Route the specialist chain accordingly — formal documents benefit from writing-architect for structure; creative work needs less scaffolding. Clarify audience, purpose, format, tone, and constraints early. Use writing-architect for structure when needed, librarian for factual support, draft-writer for the draft, editor-critic before finalizing. Do not invent facts, citations, or quotations — mark uncertain details explicitly. For verification: check structural completeness against the stated purpose, cross-reference factual claims against sources, and use available prose linting tools (markdownlint, vale, textlint) when the output format supports them.")
        ;;
      research)
        context_parts+=("Detected likely task domain: research or analysis. Use librarian for authoritative sources, briefing-analyst to synthesize findings, metis to challenge weak conclusions, editor-critic for prose-heavy deliverables. Score source quality: primary sources and official documentation rank highest, peer-reviewed publications next, then established journalism, then community content. When multiple sources conflict, present the conflict rather than choosing arbitrarily. Flag unsourced claims. Prioritize source quality, separate evidence from inference, make uncertainty explicit, and optimize for decision usefulness.")
        ;;
      operations)
        context_parts+=("Detected likely task domain: operations or professional-assistant work. Use chief-of-staff to structure the deliverable, surface missing constraints, and turn the request into a clean plan, message, checklist, or action-oriented output. Detect deliverable type: if the task implies a checklist, plan, schedule, decision matrix, or action-item tracker, structure the output accordingly. Every action item should have an owner (even if 'user'), a deadline (even if 'as soon as possible'), and a clear done-condition. If substantial writing is required, pair that with draft-writer and editor-critic.")
        ;;
      mixed)
        context_parts+=("Detected likely task domain: mixed. Split the work into coding and non-coding streams. Use the engineering specialists for code work and the writing, research, or operations specialists for the non-code deliverables. Keep the branches coordinated but do not collapse everything into one generic workflow.")
        ;;
      *)
        context_parts+=("Detected likely task domain: general. The task did not match coding, writing, research, or operations keywords — classify it yourself before proceeding. Ask: what is the deliverable? Is it code, prose, a decision, a plan, or something else? Then choose the specialist path that fits. If the task involves a repository, treat it as coding. If it involves producing a document, treat it as writing. If it involves gathering information, treat it as research. Do not default to code-oriented repo exploration unless the task truly requires it.")
        ;;
    esac

    # UI/design-aware coding: when the prompt signals frontend/UI work,
    # augment the coding hint with design-quality guidance so the main thread
    # establishes visual direction and knows about the design-reviewer gate.
    # Use the shared detector rather than a raw grep: it needs to catch common
    # asks like "create a login page" while staying away from backend prompts
    # with ambiguous words like "form parser" or "CSS loading".
    #
    # Opt-out tokens suppress the full design ritual when the user has
    # explicitly said they want minimal/functional output. These are checked
    # before the UI hint fires so the user can override the heuristic without
    # restarting the session. Mitigates false positives from prompts like
    # "the API returns a modal config object" or "add a ui_metadata field"
    # where `is_ui_request` would match `modal` / `ui` but the intent is
    # backend-only.
    ui_design_opt_out=0
    if grep -Eiq '(no design polish|functional only|backend only|skip design|skip the design|bare.?minimum ui|minimal ui|no ui polish|no visual polish)' <<<"${PROMPT_TEXT}"; then
      ui_design_opt_out=1
    fi

    if [[ "${ui_design_opt_out}" -eq 0 ]] \
        && { [[ "${TASK_DOMAIN}" == "coding" || "${TASK_DOMAIN}" == "mixed" ]]; } \
        && is_ui_request "${PROMPT_TEXT}"; then

      # Detect UI platform, intent, and domain. These compose to produce the
      # right context-aware hint: Tier-mapped guidance, platform-specific
      # contract anchor, domain archetype family suggestion. All three
      # detectors degrade to safe defaults when signals are weak.
      ui_platform="$(infer_ui_platform "${PROMPT_TEXT}" "${_project_profile}")"
      ui_intent="$(infer_ui_intent "${PROMPT_TEXT}")"
      ui_domain="$(infer_ui_domain "${PROMPT_TEXT}")"

      # Tier hint per intent — Tier B+ (NEW) is the polish-class refinement
      # that avoids the "polish→Tier C preserve" bug.
      case "${ui_intent}" in
        build) ui_tier_hint="Tier A (full 9-section contract — greenfield/redesign)" ;;
        style) ui_tier_hint="Tier B (palette + typography + visual signature only — surface theming)" ;;
        polish) ui_tier_hint="Tier B+ (palette + typography + signature + component states + density rhythm — refine, do NOT preserve tokens)" ;;
        fix) ui_tier_hint="Tier C (preserve existing tokens; do not redesign — a fix prompt should not re-emit the contract)" ;;
        *) ui_tier_hint="Tier A (default — full contract until intent is clear)" ;;
      esac

      # Platform-specific block — each platform has its own contract surface
      # and its own routing destination (which agent owns the work).
      case "${ui_platform}" in
        ios)
          ui_platform_block="**Platform: iOS / Apple native.** Route through the \`ios-ui-developer\` agent which carries the iOS-specific 9-section contract (HIG iOS 26 — Hierarchy/Harmony/Consistency, SF Symbols 7 with custom symbols, Dynamic Type up to AX5, custom accent over \`.systemBlue\`, Materials/Liquid Glass for depth, haptics for primary actions). Archetype priors: Things 3, Halide, Mercury Weather, Bear, Linear iOS, Tot, Reeder, Day One, Telegram, Cash App. Anti-patterns to avoid: \`.systemBlue\` everywhere, stock tab bar with default SF Symbols, no Dynamic Type, no Liquid Glass on iOS 26+, drop-shadow depth instead of materials."
          ;;
        macos)
          ui_platform_block="**Platform: macOS / Apple native.** Route through the \`ios-ui-developer\` agent (Apple-platforms scope covers macOS) plus consider AppKit/Catalyst patterns: NSSplitView sidebar+inspector, NSToolbar with customizable items, NSMenu, vibrancy materials, full keyboard-first nav, menu-bar app patterns where applicable. Anti-patterns: iOS-port aesthetics on Mac (touch-sized targets, no menu bar), web-style buttons instead of native push buttons, missing keyboard shortcuts."
          ;;
        cli)
          ui_platform_block="**Platform: CLI / TUI.** Apply CLI design discipline (per clig.dev guidelines): human-first output with \`--json\` / \`--plain\` for machines; respect \`NO_COLOR\` environment variable and disable color when stdout is not a TTY; errors are teaching moments (\"Can't write to file.txt — try \`chmod +w file.txt\`\") not stack-trace dumps; \`--help\` is scannable with examples first; semantic exit codes; \`-\` for stdin support; print state changes; never emit rainbow ANSI confetti. For TUI: charm.sh stack archetypes (Bubble Tea + Lip Gloss for Go, ratatui for Rust); reference points lazygit, fzf, ripgrep, bat, btop, helix, fish, starship. Color used as signal not decoration. Monospace hierarchy: bold for emphasis, dim for secondary, color for state."
          ;;
        web|*)
          ui_platform_block="**Platform: web.** Route through the \`frontend-developer\` agent which carries the web 9-section contract + 15 brand archetypes (Linear, Stripe, Vercel, Notion, Apple, Airbnb, Spotify, Tesla, Figma, Discord, Raycast, Anthropic, Webflow, Mintlify, Supabase). Anti-patterns to avoid: default Tailwind blue, centered-hero-with-CTA, three identical feature cards, Inter with no typographic styling, uniform \`py-16\` everywhere, blue-to-purple gradient backgrounds, stock-illustration SVGs, \"Get Started\"/\"Learn More\" as the only CTA copy."
          ;;
      esac

      # Domain hint — recommend archetype family that fits the product's
      # category. Caller is told to differentiate from the recommended set.
      case "${ui_domain}" in
        fintech) ui_domain_hint="**Domain: fintech.** Archetype affinity: Stripe (precision + premium gradients), Linear (sharp restraint), Mercury (gradient-as-data), Cash App (monumental numerics), Robinhood (single-accent green). Convey trust + clarity; avoid gimmicks." ;;
        wellness) ui_domain_hint="**Domain: wellness.** Archetype affinity: Calm, Headspace, Apple Health, Sleep Cycle, Mercury Weather. Convey calm + breathing room; warm palettes, gradient atmospherics, restraint over density." ;;
        creative) ui_domain_hint="**Domain: creative.** Archetype affinity: Figma, Arc, Linear, Things 3, Bear. Convey craft + expressive moments; let one visual signature carry weight." ;;
        devtool) ui_domain_hint="**Domain: developer tool.** Archetype affinity: Linear, Raycast, Vercel, Supabase, GitHub. Convey precision + density; monochrome with one accent; monospace prominence acceptable." ;;
        editorial) ui_domain_hint="**Domain: editorial.** Archetype affinity: NYT, Medium, Anthropic, Reeder, Bear. Convey reading rhythm + restraint; serif display + generous line-height; chrome that defers to content." ;;
        education) ui_domain_hint="**Domain: education.** Archetype affinity: Notion (warm clarity), Things 3 (delight), Day One (approachability). Convey clarity + warmth; avoid corporate stiffness; bright accents acceptable when restrained." ;;
        enterprise) ui_domain_hint="**Domain: enterprise / B2B.** Archetype affinity: Linear, Stripe, IBM Carbon, Atlassian. Convey reliability + density without sterility; functional palette + tight typography." ;;
        consumer) ui_domain_hint="**Domain: consumer.** Archetype affinity: Airbnb (warm coral), Spotify (vibrant green on dark), Notion, Discord (friendly blurple). Convey approachability + delight; richer color OK; rounded over angular." ;;
        *) ui_domain_hint="**Domain: unspecified.** No archetype family pre-selected — use prompt context to pick the closest archetype, then commit to three things you will do *differently* to avoid cloning." ;;
      esac

      # Persist platform/domain to state so SubagentStop can attribute
      # downstream archetype-record rows correctly when the contract is
      # captured.
      with_state_lock_batch \
        "ui_platform" "${ui_platform}" \
        "ui_domain" "${ui_domain}" \
        "ui_intent" "${ui_intent}" 2>/dev/null || true

      # Cross-session archetype memory: when the same project has
      # ≥2 prior archetype anchors, advise picking a different one this
      # session to prevent the harness from converging on the same
      # archetype across sessions in the same project. Closes v1.15.0
      # metis F7 deferred item.
      ui_archetype_advisory=""
      _prior_archetypes="$(recent_archetypes_for_project 5 2>/dev/null || true)"
      if [[ -n "${_prior_archetypes}" ]]; then
        _prior_count="$(printf '%s\n' "${_prior_archetypes}" | grep -c .)"
        if [[ "${_prior_count}" -ge 2 ]]; then
          _prior_csv="$(printf '%s' "${_prior_archetypes}" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')"
          ui_archetype_advisory=" **Prior archetypes in this project (${_prior_count}):** ${_prior_csv}. Pick a *different* archetype this session — repeating any of those above defeats the cross-session variation discipline. If the closest fit really is one of those priors, name a deliberately distinct anchor for ≥2 of the contract's 9 sections (e.g. typography from a different source, color discipline from another)."
        fi
      fi

      context_parts+=("UI/design work detected — context-aware design routing engaged. Before writing UI code, establish a visual direction using the **9-section Design Contract** ((1) Visual Theme & Atmosphere, (2) Color Palette & Roles, (3) Typography Rules, (4) Component Stylings, (5) Layout Principles, (6) Depth & Elevation, (7) Do's and Don'ts, (8) Responsive Behavior, (9) Agent Prompt Guide). Apply ${ui_tier_hint}. ${ui_platform_block} ${ui_domain_hint} Pick the closest brand archetype as point of departure, then commit to at least three specific things you will do *differently* to avoid cloning — anti-anchoring forces differentiation.${ui_archetype_advisory} **Cross-generation discipline:** never converge on common AI choices (Space Grotesk, Inter at default weight, Tailwind blue-500/indigo-500, centered-hero+CTA, three uniform feature cards, gradient-mesh backgrounds, default blue→purple) — vary palette, typography, and structural pattern across sessions. If \`DESIGN.md\` exists at project root, read it first and treat its commitments as a prior; if absent, emit your contract inline under a \`## Design Contract\` heading and offer the user persistence — **never auto-write or overwrite files at the project root**. The design-reviewer quality gate auto-activates when UI files (.tsx, .jsx, .vue, .css, .html) are edited and grades against the contract (or DESIGN.md if present). The /frontend-design skill is available for dedicated design-first workflows. To suppress this guidance, include 'no design polish' or 'functional only' in your prompt.")
      log_hook "prompt-intent-router" "UI/design context injected (platform=${ui_platform} intent=${ui_intent} domain=${ui_domain}${ui_archetype_advisory:+ priors=${_prior_count}})"
    elif [[ "${ui_design_opt_out}" -eq 1 ]]; then
      log_hook "prompt-intent-router" "UI/design opt-out detected — skipping contract injection"
    fi

    # Council evaluation detection: broad whole-project evaluation requests
    # get additional guidance to dispatch multi-role perspective lenses.
    if is_council_evaluation_request "${PROMPT_TEXT}"; then
      _council_deep_hint=""
      _council_polish_hint=""
      _council_phase7_hint=""
      _council_phase8_hint=""
      # Flag detection regex requires whitespace boundaries on both
      # sides (or string start/end) so variants like `--deep=true`,
      # `--deeper`, `--deepish` are NOT recognized — matches the SKILL.md
      # contract that bare-token form is the only accepted shape.
      # The previous `[^[:alnum:]_-]` boundary leaked `=` through (since
      # `=` is none of alnum/underscore/hyphen) and matched `--deep=true`.
      if [[ "${OMC_COUNCIL_DEEP_DEFAULT}" == "on" ]] \
          || [[ "${PROMPT_TEXT}" =~ (^|[[:space:]])--deep([[:space:]]|$) ]]; then
        _council_deep_hint=" Use --deep mode: pass \`model: \"opus\"\` to each Agent dispatch call to escalate the lens model from sonnet to opus, and extend each lens's instruction with: 'This is a deep-mode evaluation. Take more turns to investigate suspicious findings. Read source files carefully rather than relying on directory structure inference. Report uncertainty explicitly when evidence is thin.'"
      fi
      # --polish flag — narrows the lens roster to taste/excellence
      # concerns and extends dispatch with a Jobs-grade evaluation
      # rubric. Auto-activates on polish-saturated projects (the
      # standard ship-readiness audit is the wrong lens for a project
      # that's already past those gates). Composes with --deep — both
      # flags can apply to the same dispatch. When auto-activated by
      # the maturity prior, the announcement clause prefixes the hint
      # so the user sees in their first response that the lens roster
      # was narrowed automatically rather than by their explicit flag.
      _polish_explicit=0
      _polish_auto=0
      if [[ "${PROMPT_TEXT}" =~ (^|[[:space:]])--polish([[:space:]]|$) ]]; then
        _polish_explicit=1
      fi
      if [[ "${_project_maturity}" == "polish-saturated" ]]; then
        _polish_auto=1
      fi
      if [[ "${_polish_explicit}" -eq 1 || "${_polish_auto}" -eq 1 ]]; then
        if [[ "${_polish_explicit}" -eq 1 ]]; then
          _polish_origin="explicit --polish flag"
        else
          _polish_origin="auto-activated by polish-saturated project-maturity prior — surface this in your opening response so the user knows their default lens roster was narrowed"
        fi
        _council_polish_hint=" **--polish mode active** (origin: ${_polish_origin}): narrow the lens roster to \`visual-craft-lens\` + \`product-lens\` + \`design-lens\` (skip security/data/sre/growth unless the user named them explicitly — those audits are the wrong tool for a polish-saturated project that has already passed them). Pass \`model: \"opus\"\` to each Agent dispatch (escalate the lens model). Extend each lens's instruction with the Jobs-grade rubric: **soul** (does this feel like a single hand designed it, or a kit assembled?), **signature** (one specific visual or interaction the user would recognize across products), **voice** (copy + tone consistency at every micro-surface — empty states, errors, settings, onboarding — without AI-isms like 'I'll help you with that' / 'something went wrong' / 'try again'), **negative space** (does the chrome defer to the content?), **first-five-minutes** (what is the experience for a brand-new user opening this for the first time? where does the wow moment land, or does it not?), **AI-as-experience** (does the AI behavior feel like a product feature with its own voice, or a wrapped API call?), **no-cloning discipline** (commit to ≥3 specific things you'd do differently from the closest archetype). Report findings against this rubric explicitly — do not collapse it into a generic 'design quality' verdict."
      fi
      _council_phase7_hint="
7. Verify the top of the stack: pick the 2-3 highest-impact findings and re-dispatch \`oracle\` per finding to verify each claim against the actual code before presenting. Mark each as ✓ verified, ◑ refined, or ✗ demoted/dropped. Cap at 3."
      _council_authorization_hint=""
      if is_exhaustive_authorization_request "${PROMPT_TEXT}"; then
        _council_authorization_hint=" **EXHAUSTIVE AUTHORIZATION DETECTED**: the prompt explicitly authorizes exhaustive implementation (one of the canonical Phase 8 entry markers fired — see council/SKILL.md Step 8 for the full vocabulary). Skip the Scope-explosion pre-authorization pause; proceed through ALL waves end-to-end without a confirmation gate; do NOT clip scope to the five-priority headline. Wave grouping: 5–10 findings per wave by surface area is a HARD bar — never produce a plan with avg <3 findings/wave when total findings ≥5; merge adjacent surfaces if needed."
      fi
      if is_execution_intent_value "${TASK_INTENT}"; then
        # Phase 8 directive — restructured (v1.22.0) from a single ~800-word
        # paragraph to a scannable ordered checklist. The wave-grouping rule
        # is promoted to bullet 1 because it was previously buried mid-
        # paragraph (the v1.21.0 5x1-wave UX regression evidence). Embedded
        # newlines render as line breaks in the model's context.
        _council_phase8_hint="
8. **Execute the assessment (Phase 8).** Step 7's presentation is NOT the finish line — the user asked for implementation.${_council_authorization_hint}

   **A. Wave grouping (HARD bar):** aim for 5-10 findings per wave by surface area. Avg <3 findings/wave on a master list of ≥5 findings is over-segmentation — merge adjacent surfaces until each wave is substantive. Single-finding waves are acceptable only when the master list itself has <5 findings, or when one finding is critical enough to own its own wave (rare — name the reason in the wave commit body). The wave-shape gate in stop-guard.sh enforces this structurally.

   **B. Resume check first:** run \`record-finding-list.sh counts\` and \`status-line\`. If a wave plan already exists with pending findings, do NOT re-bootstrap (init refuses by default; --force would clobber progress). Re-enter at the in-progress wave.

   **C. Otherwise bootstrap** the master finding list with stable IDs (F-001, F-002, ...): \`echo '[{\"id\":\"F-001\",\"summary\":\"...\",\"severity\":\"critical\",\"surface\":\"...\",\"effort\":\"S\"}, ...]' | record-finding-list.sh init\` (auto-discovers the active session). Include \`requires_user_decision: true\` and \`decision_reason: \"...\"\` on findings needing user input (taste, policy, brand voice, credible-approach split). Then \`record-finding-list.sh assign-wave <idx> <total> <surface> F-xxx F-yyy ...\` per wave.

   **D. Per-wave cycle (every wave, end-to-end):** quality-planner → implementation specialist → quality-reviewer on the wave's diff → excellence-reviewer for the wave's surface → verification → per-wave commit titled \`Wave N/M: <surface> (F-xxx, ...)\` → \`record-finding-list.sh status F-xxx shipped <commit-sha>\` per finding. If a wave reveals a NEW finding that the master list missed, append it via \`record-finding-list.sh add-finding\` and assign-wave it; do NOT silently fix outside the master list.

   **E. Pause on USER-DECISION findings:** when a wave contains a finding with \`requires_user_decision: true\`, surface that finding's summary + decision_reason to the user before executing the fix. Do NOT choose autonomously — that is the rule's purpose. For findings discovered post-bootstrap, run \`record-finding-list.sh mark-user-decision <id> <reason>\`.

   **F. Authorization check before scope-clipping:** if the prompt did NOT explicitly authorize exhaustive implementation (no canonical Phase 8 entry marker fired — the marker list is in council/SKILL.md Step 8 and the predicate \`is_exhaustive_authorization_request()\` mirrors it), surface the wave plan first and apply the Scope explosion pause case from core.md. Otherwise proceed through ALL waves end-to-end. Do NOT clip scope to the five-priority headline (that rule is presentation-only); do NOT collapse waves into one mega-commit; do NOT defer waves to a future session.

   **G. Final summary:** run \`record-finding-list.sh summary\` for the markdown finding-status table — USER-DECISION findings appear in their own column AND are surfaced separately for visibility. Restate the key deliverable in the response so the user does not have to scroll."
      fi
      context_parts+=("COUNCIL EVALUATION DETECTED: This is a broad project evaluation request. Use the /council protocol to dispatch multi-role expert perspectives:
1. Inspect the project to determine its type, maturity, and tech stack.
2. Select 3-6 relevant role-lenses from: product-lens, design-lens, visual-craft-lens, security-lens, data-lens, sre-lens, growth-lens. Use the selection guide in the council skill to decide which lenses fit this project. design-lens and visual-craft-lens are disjoint by design (UX flow vs. visual craft) — dispatch both for projects where both surfaces matter.
3. Dispatch ALL selected lenses in parallel using the Agent tool in a single message. Each gets the project context and its evaluation mandate.${_council_deep_hint}${_council_polish_hint}
4. Wait for ALL lenses to return before synthesizing — do NOT begin synthesis early.
5. Synthesize findings: deduplicate, rank by severity x breadth, attribute to perspectives, separate quick wins from strategic work. Reject findings that lack file/line evidence. **Mark user-decision findings:** when a finding involves taste, policy, brand voice, pricing, data-retention, release attribution, or a credible-approach split (two reasonable paths where choosing wrong costs significant rework), tag it with \`requires_user_decision: true\` and a one-line \`decision_reason\` explaining what the user needs to weigh in on. These findings are surfaced separately in Phase 8 — the wave executor pauses on them instead of choosing autonomously. The criterion mirrors core.md's pause cases.
6. Present a unified Project Council Assessment with: critical findings, high-impact improvements, strategic recommendations, cross-perspective tensions, and quick wins.${_council_phase7_hint}${_council_phase8_hint}
Challenge the project — the value is in what is missing or wrong, not in what is already good.")
      log_hook "prompt-intent-router" "council evaluation detected${_council_deep_hint:+ (deep)}${_council_polish_hint:+ (polish)}${_council_phase8_hint:+ (execute)}${_council_authorization_hint:+ (exhaustive-auth)}"
    elif [[ "${advisory_prompt}" -eq 1 ]]; then
      # Advisory prompt that did NOT trigger council → inject code-grounding guidance.
      # Council dispatch is a superset of "inspect before recommending", so this only
      # fires for non-council advisory prompts over code.
      effective_domain="${TASK_DOMAIN:-${previous_domain:-}}"
      if [[ "${effective_domain}" == "coding" || "${effective_domain}" == "mixed" ]]; then
        context_parts+=("ADVISORY OVER CODE: This is an advisory task that targets a codebase. Build and test the project before forming recommendations. When launching parallel Explore agents, give each a distinct non-overlapping scope. Do NOT deliver the final structured report until all exploration agents have returned — deliver status updates while waiting, but hold the synthesis. Verify the highest-impact claims against actual code. Cover multiple layers: code correctness, user-facing copy/messaging, build/config/deployment, and external dependencies.")
      fi
    fi
  fi
fi

if grep -Eiq '(^|[^[:alnum:]_-])ultrathink([^[:alnum:]_-]|$)' <<<"${PROMPT_TEXT}"; then
  context_parts+=("ULTRATHINK MODE ACTIVE — deeper investigation required. Favor verification over abstraction: check claims against real code, run tests, read actual files rather than reasoning about what they probably contain. Before acting: consider what could go wrong and verify your assumptions are grounded. After results: ask whether you found concrete evidence or just formed an opinion — if the latter, investigate further. When you encounter ambiguity, read the source rather than reason about it. This mode is for hard problems where unverified assumptions produce wrong answers.")
fi

# Auto-memory skip directive (v1.20.0). The auto-memory wrap-up rule
# (auto-memory.md) and compact-time memory sweep (compact.md) target
# execution / continuation / checkpoint turns where work moved forward.
# Advisory and session-management turns produce evaluation, not durable
# signal worth keeping across sessions — writing project_*.md from those
# turns is the dominant noise pattern the rule rewrite is designed to
# eliminate. Inject a SKIP directive so the model treats those turns as
# memory-quiet by default.
#
# Fires regardless of ULW state — auto-memory.md / compact.md load via
# @-import in every session, so the skip directive must reach the model
# in every session too. Suppressed when auto_memory=off (no rule to
# skip) and when intent is execution / continuation / checkpoint
# (those turns are the rule's intended audience).
if [[ "${TASK_INTENT}" == "advisory" || "${TASK_INTENT}" == "session_management" ]] \
    && is_auto_memory_enabled 2>/dev/null; then
  context_parts+=("AUTO-MEMORY SKIP: this turn is classified as ${TASK_INTENT//_/-}. The session-stop and compact-time auto-memory rules in auto-memory.md and compact.md target execution/continuation/checkpoint turns where work moved forward. Skip both passes this turn unless the user explicitly asks you to remember something. Advisory and session-management turns produce evaluation, not durable signal worth keeping across sessions.")
fi

# Memory drift hint (v1.20.0). When the user-scope auto-memory dir
# contains files older than 30 days, surface a one-line nudge at session
# start so the model treats stale memory as drift-prone — verify named
# files / flags / versions against current code before relying on them.
# One-shot per session, guarded by `memory_drift_hint_emitted` state
# flag. The hint points at /memory-audit for triage. Suppressed by the
# helper itself when auto_memory=off, when the memory dir is absent, or
# when no stale files exist.
if [[ -z "$(read_state "memory_drift_hint_emitted")" ]]; then
  drift_msg="$(check_memory_drift 2>/dev/null || true)"
  if [[ -n "${drift_msg}" ]]; then
    context_parts+=("${drift_msg}")
    write_state "memory_drift_hint_emitted" "1"
  fi
fi

# Guard exhaustion warning from previous response
guard_exhausted="$(read_state "guard_exhausted")"
if [[ -n "${guard_exhausted}" ]]; then
  guard_detail="$(read_state "guard_exhausted_detail")"
  # Translate raw state variable names into human-readable descriptions
  # so the injected warning is legible to both Claude and the user reading
  # the transcript. E.g., "review=1,verify=1" → "code review, verification".
  human_detail=""
  if [[ "${guard_detail}" == *"review=1"* ]]; then
    human_detail="${human_detail:+${human_detail}, }code review"
  fi
  if [[ "${guard_detail}" == *"verify=1"* ]]; then
    human_detail="${human_detail:+${human_detail}, }test verification"
  fi
  if [[ "${guard_detail}" == *"verify_failed=1"* ]]; then
    human_detail="${human_detail:+${human_detail}, }failing tests"
  fi
  if [[ "${guard_detail}" == *"unremediated=1"* ]]; then
    human_detail="${human_detail:+${human_detail}, }unaddressed review findings"
  fi
  if [[ "${guard_detail}" == *"low_confidence=1"* ]]; then
    human_detail="${human_detail:+${human_detail}, }low-confidence verification"
  fi
  if [[ "${guard_detail}" == *"dimensions_missing="* ]]; then
    dims_part="${guard_detail##*dimensions_missing=}"
    # Replace commas with ", " for readability; the dimensions_missing
    # value is always the sole content of guard_detail when present.
    dims_part="${dims_part//,/, }"
    human_detail="${human_detail:+${human_detail}, }reviewer dimensions (${dims_part})"
  fi
  human_detail="${human_detail:-${guard_detail}}"
  context_parts+=("WARNING — PREVIOUS RESPONSE INCOMPLETE: The stop guard was exhausted after 3 blocks. Missing quality gates: ${human_detail}. Before starting new work, verify and review the previous changes if they haven't been checked yet. Briefly tell the user about this gap.")
  write_state_batch "guard_exhausted" "" "guard_exhausted_detail" ""
fi

# Cross-session learning: inject defect watch list when context is being built
# so the model is primed to look for historically frequent defect categories.
if is_execution_intent_value "${TASK_INTENT}"; then
  defect_watch="$(get_defect_watch_list 3 2>/dev/null || true)"
  if [[ -n "${defect_watch}" ]]; then
    context_parts+=("Historical defect patterns from prior sessions — ${defect_watch}. Pay extra attention to these categories during implementation and review.")
  fi
fi

if [[ "${#context_parts[@]}" -eq 0 ]]; then
  exit 0
fi

context_text="$(printf '%s\n' "${context_parts[@]}")"

jq -nc --arg context "${context_text}" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $context
  }
}'
