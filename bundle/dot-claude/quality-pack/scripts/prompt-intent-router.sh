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
  "last_user_prompt_ts" "$(now_epoch)" \
  "stall_counter" "0"
append_limited_state \
  "recent_prompts.jsonl" \
  "$(jq -nc --arg ts "$(now_epoch)" --arg text "${PROMPT_TEXT}" '{ts:$ts,text:$text}')" \
  "12"

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
  fi

  if [[ "${session_management_prompt}" -eq 0 && "${checkpoint_prompt}" -eq 0 ]]; then
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
- domain-specific execution → the closest specialist engineering agent
Discipline:
- Make changes incrementally — one logical change, verify it, then proceed.
- Test rigorously after edits — failing to test is the #1 failure mode.
- Before invoking the reviewer, self-assess: enumerate every component of the request and verify each is delivered.
- Run quality-reviewer before stopping. For complex or multi-file tasks, also run excellence-reviewer after defects are addressed for a fresh-eyes completeness and polish evaluation.
- Never write placeholder stubs or sycophantic comments.
- Never call an unfamiliar or version-sensitive library/API from memory — confirm the surface in current docs first.")
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
      _council_phase7_hint=""
      _council_phase8_hint=""
      if [[ "${OMC_COUNCIL_DEEP_DEFAULT}" == "on" ]] \
          || [[ "${PROMPT_TEXT}" =~ (^|[^[:alnum:]_-])--deep([^[:alnum:]_-]|$) ]]; then
        _council_deep_hint=" Use --deep mode: pass \`model: \"opus\"\` to each Agent dispatch call to escalate the lens model from sonnet to opus, and extend each lens's instruction with: 'This is a deep-mode evaluation. Take more turns to investigate suspicious findings. Read source files carefully rather than relying on directory structure inference. Report uncertainty explicitly when evidence is thin.'"
      fi
      _council_phase7_hint="
7. Verify the top of the stack: pick the 2-3 highest-impact findings and re-dispatch \`oracle\` per finding to verify each claim against the actual code before presenting. Mark each as ✓ verified, ◑ refined, or ✗ demoted/dropped. Cap at 3."
      if is_execution_intent_value "${TASK_INTENT}"; then
        _council_phase8_hint="
8. Execute the assessment (Phase 8). Step 7's presentation is NOT the finish line for this prompt — the user asked for implementation. **Resume check first:** run \`record-finding-list.sh counts\` — if a wave plan already exists with pending findings, do NOT re-bootstrap (init refuses by default; --force would clobber progress). Re-enter at the in-progress wave instead. **Otherwise bootstrap** the master finding list with stable IDs (F-001, F-002, ...): \`echo '[{\"id\":\"F-001\",\"summary\":\"...\",\"severity\":\"critical\",\"surface\":\"...\",\"effort\":\"S\"}, ...]' | record-finding-list.sh init\` (script auto-discovers the active session). Then \`record-finding-list.sh assign-wave <idx> <total> <surface> F-xxx F-yyy ...\` per wave, and \`record-finding-list.sh status F-xxx shipped <commit-sha> '<notes>'\` after each fix. **If a wave reveals a new finding** that was missed, append it via \`record-finding-list.sh add-finding <<< '{\"id\":\"F-NNN\",\"summary\":\"...\",\"severity\":\"...\",\"surface\":\"...\"}'\` and assign-wave it; do NOT silently fix outside the master list. Group findings into 5–10-finding waves by surface area, and execute each wave fully (quality-planner → implementation specialist → quality-reviewer on the wave's diff → excellence-reviewer for the wave's surface → verification → per-wave commit titled 'Wave N/M: <surface> (F-xxx, ...)'). Do NOT clip scope to the five-priority headline (that rule is presentation-only); do NOT collapse waves into one mega-commit; do NOT defer waves to a future session. If the prompt did NOT explicitly authorize exhaustive implementation (no 'implement all' / 'exhaustive' / 'every item' / 'address each one' / 'fix everything' tokens), surface the wave plan first and apply the Scope explosion pause case from core.md. Full Phase 8 protocol is in the council skill definition. Final summary: run \`record-finding-list.sh summary\` for the markdown finding-status table."
      fi
      context_parts+=("COUNCIL EVALUATION DETECTED: This is a broad project evaluation request. Use the /council protocol to dispatch multi-role expert perspectives:
1. Inspect the project to determine its type, maturity, and tech stack.
2. Select 3-6 relevant role-lenses from: product-lens, design-lens, security-lens, data-lens, sre-lens, growth-lens. Use the selection guide in the council skill to decide which lenses fit this project.
3. Dispatch ALL selected lenses in parallel using the Agent tool in a single message. Each gets the project context and its evaluation mandate.${_council_deep_hint}
4. Wait for ALL lenses to return before synthesizing — do NOT begin synthesis early.
5. Synthesize findings: deduplicate, rank by severity x breadth, attribute to perspectives, separate quick wins from strategic work. Reject findings that lack file/line evidence.
6. Present a unified Project Council Assessment with: critical findings, high-impact improvements, strategic recommendations, cross-perspective tensions, and quick wins.${_council_phase7_hint}${_council_phase8_hint}
Challenge the project — the value is in what is missing or wrong, not in what is already good.")
      log_hook "prompt-intent-router" "council evaluation detected${_council_deep_hint:+ (deep)}${_council_phase8_hint:+ (execute)}"
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
