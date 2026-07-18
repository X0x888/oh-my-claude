#!/usr/bin/env bash
# omc-config.sh — backend for the /omc-config skill.
#
# Inspects and mutates user/project oh-my-claude.conf via cleanly-named
# subcommands. The /omc-config skill markdown calls this script and the
# AskUserQuestion tool to produce a multi-choice setup/update/change UX.
#
# Atomic writes use tmp+mv. Reads tolerate missing files. Validation
# refuses unknown flags and out-of-range values BEFORE any write lands,
# so a malformed `set` invocation never half-writes the conf.
#
# Subcommands:
#   detect-mode                          Print setup|update|change|not-installed
#   show                                 Pretty-print current effective config
#   list-flags                           Emit known flags as JSON (for skill)
#   set <user|project> <k=v>...          Atomic write of one or more keys
#   apply-preset <user|project> <name>   Apply preset (maximum|zero-steering|balanced|minimal)
#   presets <name>                       Print preset key=value pairs to stdout
#   apply-tier <tier>                    Run switch-tier.sh (rewrites agent files)
#   install-watchdog                     Run install-resume-watchdog.sh
#   mark-completed [user|project]        Stamp omc_config_completed=<ISO date>
#
# Exit codes:
#   0 — success
#   1 — runtime failure (missing dependency, IO error)
#   2 — invalid invocation (unknown flag, bad enum value, bad scope)

set -euo pipefail

USER_CONF="${HOME}/.claude/oh-my-claude.conf"
SENTINEL_KEY="omc_config_completed"

get_project_conf() {
  printf '%s/.claude/oh-my-claude.conf' "$(pwd)"
}

# --- Static metadata about every flag this skill understands ---
#
# Format per line: name|type|default|category|description
#
# Types:
#   bool         — on|off
#   true_false   — true|false
#   int          — non-negative integer
#   enum:a/b/c   — must be one of the listed values
#   str          — free-form (validation skipped)
#
# Categories drive the grouping in `show` output and the skill's
# AskUserQuestion clusters. Order is display-order (most user-facing
# first; exotic tuning knobs last).
emit_known_flags() {
  cat <<'EOF'
gate_level|enum:basic/standard/full|full|gates|Quality-gate enforcement depth
guard_exhaustion_mode|enum:silent/scorecard/block|block|gates|Behavior when gate-block cap is reached
verify_confidence_threshold|int|40|gates|Minimum verification confidence (0-100)
quality_policy|enum:balanced/zero_steering|balanced|gates|User-only adaptive quality posture for no-steering work; project conf cannot weaken it
definition_of_excellent|enum:adaptive/always/off|adaptive|gates|User-only frozen five-axis quality contract (deliberate, distinctive, coherent, visionary, complete); adaptive arms serious/ambitious work, always arms every execution objective
quality_constitution|bool|on|memory|User-only consumption of explicit project/global quality standards stored under ~/.claude/omc-user; project conf cannot disable it
taste_learning|enum:off/review/adaptive|review|memory|User-only exact-user taste learning: review records candidates for approval; adaptive may activate repeated signals as advisory only
quality_constitution_max_context_chars|pint|2400|memory|User-only cap for compiled Constitution context; raw evidence/reference content is never injected
discovered_scope|bool|on|gates|Capture advisory findings + gate stop until addressed
advisory_no_findings_gate|bool|on|gates|Block stop when N+ advisory specialists dispatched but zero findings recorded (closes fail-open of finding-gated gates)
advisory_no_findings_threshold|int|2|gates|Specialist dispatch count that activates the advisory-no-findings gate
ulw_pause_validator|bool|on|gates|/ulw-pause validator: reject pause reasons that name technical-judgment categories without an operational signal
pause_external_blocker_threshold|int|3|gates|/ulw-pause case-2 (external blocker — rate limit / API down / network failure / dependency upgrade) requires N consecutive attempts on the same blocker before allowing the pause. Ported from openai/codex `continuation.md` 3-turn blocked threshold (v1.46-pre). 0 disables; case-1/3/4 (credentials/destructive/unfamiliar-state) and stakeholder/legal/user-auth signals bypass the gate.
pretool_intent_guard|true_false|true|gates|User-only: block destructive git/gh under non-execution intent; project conf cannot disable it
agent_first_gate|bool|off|gates|User-only: block first /ulw mutation until a fresh-context specialist returns (default off v1.43+; was mandatory pre-v1.43). See conf.example / docs/customization.md for the full rationale and when to turn it on.
bg_spawn_gate|true_false|true|gates|User-only: block Bash poll-loop + background detach (hygiene; v1.43.x); project conf cannot disable it
stall_threshold|int|12|gates|Consecutive read/grep before stall fires
excellence_file_count|int|3|gates|Breadth floor for cross-surface completeness review
dimension_gate_file_count|int|3|gates|Breadth floor combined with semantic/cross-surface evidence
traceability_file_count|int|6|gates|Breadth floor for cross-surface/plan traceability review
wave_override_ttl_seconds|int|7200|gates|Wave-plan freshness window for pretool guard
custom_verify_mcp_tools|str||gates|Pipe-separated MCP tool patterns that count as verification
metis_on_plan_gate|bool|off|advisory|Block stop on complex plan until metis stress-test
prometheus_suggest|bool|off|advisory|Declare-and-proceed scope interpretation on short product-shaped prompts
intent_verify_directive|bool|off|advisory|Declare-and-proceed goal interpretation on short unanchored prompts
exemplifying_directive|bool|on|advisory|Completeness/coverage directive — enumerate the search universe, verify each (v1.26.0 broadens to completeness verbs + advisory turns)
exemplifying_scope_gate|bool|on|gates|Require checklist for example-marker prompts before stop
objective_contract_gate|bool|on|gates|Re-anchor verbatim original objective + completion audit before stop on substantive turns (Codex /goal port; anti-premature-stop sibling of pause_external_blocker_threshold)
objective_contract_min_files|int|4|gates|Per-cycle unique-file edit count that marks an objective-cycle substantive (volume arm of the objective-completion gate; 0 disables the volume arm)
objective_contract_arm_on_god_scope|bool|on|gates|Arm the objective-completion gate on bare-imperative god-scope prompts ("improve it"/"harden"/"audit everything") as an INTENT signal, so ambitious-but-vague one-word imperatives drive relentlessly instead of stopping at round one (high-precision subset; recall-tuned open_mandate prose stays a nudge — use /goal for it)
auto_tune|bool|off|gates|Opt-in self-tuning: at most once per 7 days, raise objective_contract_min_files by 1 step (clamped [2,12]) when show-report.sh's own reprompt-rate signal clears its >=50% over-firing bar over >=10 blocks. Deny-listed at project-conf scope (rewrites your GLOBAL conf, not just this repo's).
goal_gate|bool|on|gates|Master switch for the /goal relentless driver — re-anchor a user-declared goal and block premature Stop until achieved (fresh audit + **Goal achieved.** attestation) or a no-progress stuck-wall; voluntary sibling of objective_contract_gate (inert until a goal is armed via /goal or auto-arm)
goal_stuck_threshold|int|3|gates|Consecutive no-progress /goal blocks before the stuck-wall surfaces and releases (0 = uncapped, never auto-release)
goal_auto_arm|bool|on|gates|Auto-arm the /goal relentless driver when a fresh /ulw execution prompt carries an explicit goal declaration ("don't stop until tests pass" / "your goal is ..." / "keep going until ...") — the v1.47 single-entrance embed; high-precision markers only, every auto-arm is announced, /goal clear stands down (preset sibling: objective_contract_arm_on_god_scope)
prompt_text_override|bool|on|gates|PreTool guard trusts prompt-text imperative when classifier disagrees
mark_deferred_strict|bool|on|gates|Reject low-information defer reasons (out of scope / follow-up) AND effort excuses (requires significant effort / blocked by complexity)
shortcut_ratio_gate|bool|on|gates|Soft-block when wave plan total≥10 AND deferred-to-decided ratio ≥0.5 (catches shortcut-on-big-tasks)
no_defer_mode|bool|on|gates|User-only v1.40.0 contract: under ULW execution, /mark-deferred refuses, findings status=deferred rejected, stop-guard hard-blocks on any deferred entry. Project conf cannot disable it.
god_scope_on_bare_prompt|bool|on|advisory|v1.44: bare-imperative prompts (single-word "fix"/"audit"/"ship") inject GOD-SCOPE-SCAN directive — identify-and-implement across the whole project, no clarification, no defer to next session.
exhaustive_auth_directive|bool|on|advisory|v1.46: prose open mandates ("implement all"/"comprehensively"/"make it better") inject an OPEN-MANDATE / INNOVATION-GENERATION directive — generate the delta to the most powerful version, not a defect audit; non-blocking, model honors explicit narrow scope.
circuit_breaker|bool|on|gates|v1.44-pre Port 1: PostToolUse:Bash hook — 3 consecutive same-target failures emit a revert+oracle directive and set a 60s quiet window. Enforces core.md:128 mechanically; ported from Citadel circuit-breaker.js.
transcript_archive|bool|off|telemetry|v1.44-pre Port 5: archive session JSONL to ~/.claude/quality-pack/state/<project_key>/<session_id>/transcript.json on Stop. Idempotent; disabled by default — disk cost ~50-500 KB/session.
installation_drift_check|true_false|true|advisory|Statusline yellow arrow when bundle is behind source
statusline_retention|bool|on|advisory|Statusline [gw:N] token — quality-gate blocks across all sessions in the last 7 days
statusline_width|bool|on|advisory|Statusline width fit — sheds/shrinks lowest-priority tokens until each line fits the terminal
whats_new_session_hint|true_false|true|advisory|SessionStart "you upgraded — run /whats-new" notice (once per version transition)
self_audit_nudge|bool|on|advisory|SessionStart nudge when CONTRIBUTING.md's quarterly /council --self-audit cadence is stale (>90 days or never), at most once per 7 days
lazy_session_start|bool|off|gates|Defer whats-new/drift-check/welcome SessionStart hooks to first UserPromptSubmit. Throwaway sessions skip the work AND preserve dedupe stamps for the next real session.
mid_session_memory_checkpoint|bool|on|memory|Inject MID-SESSION CHECKPOINT directive when user returns after ≥30 min idle gap. Nudges auto-memory.md sweep on the just-closed stretch before responding.
auto_memory|bool|on|memory|Cross-session auto-memory writes (project/feedback/user/reference)
repo_lessons|bool|off|memory|Team-shareable, git-committable memory — record-repo-lesson.sh prepends capped bullets to .claude/lessons.md / .claude/backlog.md at the repo root (v1.48-pre). Off by default; deny-listed at project-conf scope (data-persistence-into-repo security restriction) — user-level conf or env only.
prompt_persist|bool|on|memory|In-session prompt persistence (recent_prompts.jsonl + last_user_prompt). Off skips writes and degrades prompt-text-override gracefully.
classifier_telemetry|bool|on|telemetry|Per-turn classifier telemetry to session state
model_tier|enum:quality/balanced/economy|balanced|cost|User-only quality-first model posture: quality=inherit deliberators + Opus specialists; balanced=default split with high-risk escalation; economy=Sonnet-first with adaptive reasoning-risk escalation. Council lenses escalate only with deep. Inherit means omit model and ride the current session. Project conf cannot set this flag.
model_overrides|str||cost|User-only highest-precedence per-agent pin. Format agent:model,agent:model with opus/sonnet/haiku/inherit (e.g. oracle:inherit,librarian:haiku). Shipped bare inherit pins are materialized before live omission; custom inherit must already be definition-backed, and custom/plugin named-model pins stay runtime-only. Namespaced inherit is rejected. Env OMC_MODEL_OVERRIDES wins for enforceable pins; project conf cannot set this flag.
council_deep_default|bool|off|cost|Auto-triggered Council uses --deep routing: selected Sonnet-backed specialists escalate to Opus; inherit deliberators stay on the session model
stop_failure_capture|bool|on|watchdog|Capture resume_request.json on rate-limit / fatal stop
resume_request_ttl_days|int|7|watchdog|Days a resume_request stays claimable
resume_watchdog|bool|off|watchdog|Headless daemon launches claude --resume after cap clears
resume_watchdog_cooldown_secs|int|600|watchdog|Per-artifact cooldown between watchdog launches
resume_session_ttl_secs|int|7200|watchdog|Max lifetime for headless omc-resume tmux sessions before reaper kills them
resume_scan_max_sessions|pint|30|watchdog|Max session dirs find_claimable_resume_requests walks (caps SessionStart/watchdog/resume hot-path latency on long retention)
claude_bin|str||watchdog|Pinned absolute path to claude binary (PATH-hijack defense; auto-set by install-resume-watchdog.sh)
resume_request_per_cwd_cap|int|3|watchdog|Max resume_request artifacts per cwd before stop-failure-handler prunes oldest (0 disables)
time_tracking|bool|on|telemetry|Per-tool / per-subagent timing capture; backs Stop epilogue + /ulw-time
time_tracking_xs_retain_days|pint|30|telemetry|Cross-session timing log retention (days)
time_card_min_seconds|int|5|telemetry|Min walltime to render the Stop epilogue time card (seconds; 0 = always)
token_tracking|bool|on|telemetry|Incremental token capture from parent + nested sidechain transcripts with main/sub-agent and role/model/native-dispatch attribution; backs /ulw-time + /ulw-status + /ulw-report
state_ttl_days|int|7|cleanup|Days before stale session-state dirs are swept
output_style|enum:opencode/executive/preserve|opencode|cost|Bundled output style: opencode = oh-my-claude (compact CLI), executive = executive-brief (CEO-style status report), preserve = leave settings.json untouched
model_drift_canary|bool|on|telemetry|Stop-hook canary detects silent confabulation (claims-vs-tool-calls audit; surfaces in /ulw-report)
blindspot_inventory|bool|on|gates|Project-surface scanner backing the intent-broadening directive (lazy-cached, 24h TTL)
intent_broadening|bool|on|advisory|Inject project-context reconciliation directive on complex execution prompts (defends against language-as-limitation failure)
divergence_directive|bool|on|advisory|Inject divergent-framing directive on paradigm-shape decisions (X-vs-Y, "best way", "how should we", "design the X strategy") — enumerate 2-3 framings inline before commit
workflow_substrate|bool|on|cost|Permit Claude Code's Workflow tool (deterministic multi-subagent orchestration — parallel/pipeline, JSON output schemas, token budgets, resume; runs in background) as an OPT-IN substrate for HEAVY fan-out (council Phase 8 waves, large audits, migrations) — NOT the default per-prompt path; off keeps all work on the lightweight in-thread path
inferred_contract|bool|on|gates|Delivery Contract v2: infer required adjacent surfaces (tests/changelog/parser-lockstep/migration-notes) from actual edits, block stop when silently missed
directive_budget|enum:off/maximum/balanced/minimal|balanced|advisory|How much injected pre-answer scaffolding you see per prompt: whole-payload + optional caps trim lower-priority repetition while mandatory quality contracts remain fail-safe. minimal = leanest optional layer, maximum = widest bounded aperture, off = very high aperture with runaway ceiling, balanced = default
blindspot_ttl_seconds|pint|86400|gates|Cache TTL (seconds) for blindspot inventory; default 86400 = 24h
EOF
}

# --- Preset definitions ---
#
# `maximum`: quality + max automation (this project's intended posture).
#   Internally consistent with `model_tier=quality` — every quality lever
#   is pulled, including `council_deep_default=on` so auto-triggered
#   Council dispatches use deep routing: selected Sonnet-backed agents
#   escalate to Opus while inherit deliberators stay on the session model.
# `zero-steering`: explicit alias for maximum. It exists so a user can
#   name the outcome they want ("ship without steering") instead of
#   reverse-engineering which quality levers that implies.
# `balanced`: close to install-time defaults; safe for most users. Cost
#   caps live here, not in `maximum` — `council_deep_default=off` leaves
#   each auto-Council specialist on its normal tier for the typical user.
# `minimal`: lightest footprint while keeping core gates working.
#
# stop_failure_capture stays on across all presets — it is privacy-aware,
# tiny, and the only thing that makes /ulw-resume work after a Claude
# Code rate-limit kill. Users who actually need it off should set it
# explicitly, not adopt a preset.
#
# v1.40.0 LOAD-BEARING (do NOT optimize away): `no_defer_mode=on` MUST
# ship in `maximum`/`zero-steering` AND `balanced` presets. This is the
# recommended-preset half of the no-defer contract documented in
# `~/.claude/quality-pack/memory/core.md` ("The v1.40.0 no-defer
# contract"). A recommended preset that shipped `no_defer_mode=off`
# would teach new installs that defer is normal behavior, defeating the
# contract before it ever fires. The `minimal` preset legitimately ships
# `no_defer_mode=off` because that preset's stance is "lightest footprint
# while keeping core gates working" — power-user opt-out by design.
# Flipping any of the three values triggers tests/test-no-defer-contract.sh.
emit_preset() {
  local profile="$1"
  case "${profile}" in
    maximum|zero-steering|zero_steering)
      cat <<'EOF'
gate_level=full
guard_exhaustion_mode=block
quality_policy=zero_steering
definition_of_excellent=always
quality_constitution=on
taste_learning=adaptive
quality_constitution_max_context_chars=4000
auto_memory=on
prompt_persist=on
classifier_telemetry=on
discovered_scope=on
council_deep_default=on
prometheus_suggest=on
intent_verify_directive=on
exemplifying_directive=on
exemplifying_scope_gate=on
objective_contract_gate=on
objective_contract_arm_on_god_scope=on
goal_gate=on
goal_auto_arm=on
prompt_text_override=on
mark_deferred_strict=on
shortcut_ratio_gate=on
no_defer_mode=on
god_scope_on_bare_prompt=on
exhaustive_auth_directive=on
circuit_breaker=on
transcript_archive=off
metis_on_plan_gate=on
stop_failure_capture=on
resume_watchdog=on
time_tracking=on
token_tracking=on
model_drift_canary=on
blindspot_inventory=on
intent_broadening=on
divergence_directive=on
workflow_substrate=on
inferred_contract=on
directive_budget=maximum
model_tier=quality
EOF
      ;;
    balanced)
      cat <<'EOF'
gate_level=full
guard_exhaustion_mode=scorecard
quality_policy=balanced
definition_of_excellent=adaptive
quality_constitution=on
taste_learning=review
quality_constitution_max_context_chars=2400
auto_memory=on
prompt_persist=on
classifier_telemetry=on
discovered_scope=on
council_deep_default=off
prometheus_suggest=off
intent_verify_directive=off
exemplifying_directive=on
exemplifying_scope_gate=on
objective_contract_gate=on
objective_contract_arm_on_god_scope=on
goal_gate=on
goal_auto_arm=on
prompt_text_override=on
mark_deferred_strict=on
shortcut_ratio_gate=on
no_defer_mode=on
god_scope_on_bare_prompt=on
exhaustive_auth_directive=on
circuit_breaker=on
transcript_archive=off
metis_on_plan_gate=off
stop_failure_capture=on
resume_watchdog=off
time_tracking=on
token_tracking=on
model_drift_canary=on
blindspot_inventory=on
intent_broadening=on
divergence_directive=on
workflow_substrate=on
inferred_contract=on
directive_budget=balanced
model_tier=balanced
EOF
      ;;
    minimal)
      cat <<'EOF'
gate_level=basic
guard_exhaustion_mode=silent
quality_policy=balanced
definition_of_excellent=off
quality_constitution=off
taste_learning=off
quality_constitution_max_context_chars=1200
auto_memory=off
prompt_persist=off
classifier_telemetry=off
discovered_scope=off
council_deep_default=off
prometheus_suggest=off
intent_verify_directive=off
exemplifying_directive=off
exemplifying_scope_gate=off
objective_contract_gate=off
objective_contract_arm_on_god_scope=off
goal_gate=on
goal_auto_arm=off
prompt_text_override=on
mark_deferred_strict=off
shortcut_ratio_gate=off
no_defer_mode=off
god_scope_on_bare_prompt=off
exhaustive_auth_directive=off
circuit_breaker=off
transcript_archive=off
metis_on_plan_gate=off
stop_failure_capture=on
resume_watchdog=off
time_tracking=off
token_tracking=off
model_drift_canary=off
blindspot_inventory=off
intent_broadening=off
divergence_directive=off
workflow_substrate=off
inferred_contract=off
directive_budget=minimal
model_tier=economy
EOF
      ;;
    *)
      printf 'omc-config: unknown preset: %s (expected maximum|zero-steering|balanced|minimal)\n' "${profile}" >&2
      return 2
      ;;
  esac
}

# Read a single key from a conf file, tolerating absence.
# Last-occurrence wins (matches install.sh `set_conf` semantics).
read_conf_value() {
  local conf="$1" key="$2"
  [[ -f "${conf}" ]] || return 0
  grep -E "^${key}=" "${conf}" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Find the nearest project-scope conf by walking up from PWD, capped at
# 10 levels — same logic as `load_conf` in common.sh. Skips $HOME so the
# user conf is not double-counted as project. Prints the path and exits 0
# if found; exits 1 if no project conf exists in the walked chain.
find_project_conf() {
  local dir="${PWD}" depth=0
  while [[ "${dir}" != "/" && "${depth}" -lt 10 ]]; do
    if [[ "${dir}" != "${HOME}" && -f "${dir}/.claude/oh-my-claude.conf" ]]; then
      printf '%s' "${dir}/.claude/oh-my-claude.conf"
      return 0
    fi
    dir="$(dirname "${dir}")"
    depth=$((depth + 1))
  done
  return 1
}

# Project-conf restrictions are one contract across the runtime and config UX.
# Keep this exact list aligned with common.sh's `_parse_conf_file` deny-list and
# reuse this single local registry for reads, writes, source markers, warnings,
# and preset filtering so /omc-config cannot drift internally.
PROJECT_DENIED_FLAGS=(
  pretool_intent_guard
  bg_spawn_gate
  agent_first_gate
  no_defer_mode
  quality_policy
  definition_of_excellent
  quality_constitution
  taste_learning
  quality_constitution_max_context_chars
  model_tier
  model_overrides
  repo_lessons
  auto_tune
)

flag_is_project_denied() {
  local requested="${1:-}" denied_flag
  for denied_flag in "${PROJECT_DENIED_FLAGS[@]}"; do
    [[ "${requested}" == "${denied_flag}" ]] && return 0
  done
  return 1
}

flag_is_model_user_only() {
  case "${1:-}" in
    model_tier|model_overrides) return 0 ;;
    *) return 1 ;;
  esac
}

# Keep the write-time `inherit` authority boundary independent of custom file
# names. Shipped definitions can be reconstructed by switch-tier.sh; custom
# definitions are user-owned and must never be rewritten as a side effect of
# saving a pin. Keep these rosters lockstep with the bundle, install.sh, and
# switch-tier.sh; tests/test-omc-config.sh regression-locks their union.
OMC_CONFIG_SHIPPED_INHERIT_AGENTS='abstraction-critic chief-of-staff divergent-framer draft-writer editor-critic excellence-reviewer metis oracle prometheus quality-planner quality-reviewer release-reviewer rigor-reviewer writing-architect'
OMC_CONFIG_SHIPPED_FIXED_AGENTS='atlas backend-api-developer briefing-analyst data-lens design-lens design-reviewer devops-infrastructure-engineer frontend-developer fullstack-feature-builder growth-lens ios-core-engineer ios-deployment-specialist ios-ecosystem-integrator ios-ui-developer librarian literature-scout product-lens quality-researcher research-data-analyst security-lens sre-lens test-automation-engineer visual-craft-lens'

model_agent_is_shipped() {
  local wanted="${1:-}" agent
  for agent in ${OMC_CONFIG_SHIPPED_INHERIT_AGENTS} \
      ${OMC_CONFIG_SHIPPED_FIXED_AGENTS}; do
    [[ "${wanted}" == "${agent}" ]] && return 0
  done
  return 1
}

# `inherit` is represented by Agent-model omission, so it can only be a live
# override when the bare installed definition already declares inherit. The
# official set path materializes shipped bare pins immediately. Custom and
# plugin definitions are never rewritten; custom inherit is valid only when
# the custom file already declares it exactly once, while namespaced plugin
# inherit cannot be proven or materialized.
inherit_override_is_materialized() {
  local name="${1:-}" agent_file line model_count=0 model_value=""
  [[ "${name}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  agent_file="${HOME}/.claude/agents/${name}.md"
  [[ -f "${agent_file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      model:*)
        model_count=$((model_count + 1))
        model_value="${line#model: }"
        ;;
    esac
  done < "${agent_file}"
  [[ "${model_count}" -eq 1 && "${model_value}" == "inherit" ]]
}

inherit_override_is_materializable() {
  local name="${1:-}" agent_file model_count model_value
  [[ "${name}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  agent_file="${HOME}/.claude/agents/${name}.md"
  [[ -f "${agent_file}" ]] || return 1
  model_count="$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)"
  model_value="$(sed -n 's/^model: //p' "${agent_file}" | head -1)"
  [[ "${model_count}" == "1" \
      && "${model_value}" =~ ^(inherit|opus|sonnet|haiku)$ ]]
}

# Keep this parser in lockstep with common.sh's
# `omc_valid_model_overrides_summary`: `show` must not present a malformed or
# unenforceable environment entry as an active pin when the live resolver will
# ignore it. Namespaced plugin identities contain one additional colon, so
# split on the final colon rather than the first.
valid_model_overrides_summary() {
  local raw="${1:-}" pair name model summary=""
  local -a pairs=()
  [[ -z "${raw}" ]] && return 0
  IFS=',' read -ra pairs <<< "${raw}"
  for pair in "${pairs[@]}"; do
    pair="${pair//[[:space:]]/}"
    [[ "${pair}" == *:* ]] || continue
    name="${pair%:*}"
    model="${pair##*:}"
    [[ "${name}" =~ ^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+)?$ ]] || continue
    case "${model}" in
      opus|sonnet|haiku|inherit) ;;
      *) continue ;;
    esac
    if [[ "${model}" == "inherit" ]] \
        && ! inherit_override_is_materialized "${name}"; then
      continue
    fi
    summary="${summary}${summary:+,}${name}:${model}"
  done
  printf '%s' "${summary}"
}

model_overrides_have_invalid_entries() {
  local raw="${1:-}" normalized pair name model
  local -a pairs=()
  [[ -z "${raw}" ]] && return 1
  normalized="${raw//[[:space:]]/}"
  [[ -n "${normalized}" ]] || return 0
  case "${normalized}" in
    ,*|*,|*,,*) return 0 ;;
  esac
  IFS=',' read -ra pairs <<< "${normalized}"
  for pair in "${pairs[@]}"; do
    [[ -n "${pair}" ]] || return 0
    if [[ "${pair}" != *:* ]]; then
      return 0
    fi
    name="${pair%:*}"
    model="${pair##*:}"
    if [[ ! "${name}" =~ ^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+)?$ ]]; then
      return 0
    fi
    case "${model}" in
      opus|sonnet|haiku|inherit) ;;
      *) return 0 ;;
    esac
    if [[ "${model}" == "inherit" ]] \
        && ! inherit_override_is_materialized "${name}"; then
      return 0
    fi
  done
  return 1
}

# Strict write-time validator. Runtime and `show` intentionally fail soft for
# hand-edited legacy config, but `/omc-config set` must not persist a value the
# resolver will partly or wholly discard. Empty is the supported clear action.
# Shipped bare inherit is accepted because the write path can materialize it.
# Custom bare inherit is accepted only when the user-owned definition already
# declares inherit exactly once. Namespaced inherit is rejected because
# Agent-model omission cannot rewrite or prove a plugin definition. Explicit
# named-model custom/plugin pins remain valid runtime-only pins.
model_overrides_value_is_valid() {
  local raw="${1-}" normalized pair name model
  local -a pairs=()
  [[ -z "${raw}" ]] && return 0
  normalized="${raw//[[:space:]]/}"
  [[ -n "${normalized}" ]] || return 1
  case "${normalized}" in
    ,*|*,|*,,*) return 1 ;;
  esac
  IFS=',' read -ra pairs <<< "${normalized}"
  [[ "${#pairs[@]}" -gt 0 ]] || return 1
  for pair in "${pairs[@]}"; do
    [[ "${pair}" == *:* ]] || return 1
    name="${pair%:*}"
    model="${pair##*:}"
    [[ "${name}" =~ ^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+)?$ ]] \
      || return 1
    case "${model}" in
      opus|sonnet|haiku|inherit) ;;
      *) return 1 ;;
    esac
    if [[ "${model}" == "inherit" ]]; then
      [[ "${name}" != *:* ]] || return 1
      if model_agent_is_shipped "${name}"; then
        inherit_override_is_materializable "${name}" || return 1
      else
        inherit_override_is_materialized "${name}" || return 1
      fi
    fi
  done
  return 0
}

# User-conf values as the runtime actually consumes them. This is deliberately
# fail-soft: manually edited malformed rows remain on disk for diagnosis, but
# never appear as active values in `show`/`list-flags`.
read_effective_user_conf_value() {
  local key="$1" raw
  raw="$(read_conf_value "${USER_CONF}" "${key}")"
  case "${key}" in
    model_tier)
      case "${raw}" in
        quality|balanced|economy) printf '%s' "${raw}" ;;
      esac
      ;;
    model_overrides)
      valid_model_overrides_summary "${raw}"
      ;;
    *) printf '%s' "${raw}" ;;
  esac
}

# The common runtime gives valid environment values precedence over both conf
# scopes. `/omc-config show` reproduces that for the user-facing model controls.
# A malformed tier is ignored so it cannot silently demote a saved Quality
# posture; user conf wins, or Balanced remains the no-valid-source default.
model_env_override_value() {
  case "${1:-}" in
    model_tier)
      [[ -n "${OMC_MODEL_TIER:-}" ]] || return 1
      case "${OMC_MODEL_TIER}" in
        quality|balanced|economy) printf '%s' "${OMC_MODEL_TIER}" ;;
        *) return 1 ;;
      esac
      ;;
    model_overrides)
      [[ -n "${OMC_MODEL_OVERRIDES:-}" ]] || return 1
      local valid_overrides
      valid_overrides="$(valid_model_overrides_summary \
        "${OMC_MODEL_OVERRIDES}")"
      [[ -n "${valid_overrides}" ]] || return 1
      printf '%s' "${valid_overrides}"
      ;;
    *) return 1 ;;
  esac
}

runtime_env_override_value() {
  local key="${1:-}" value=""
  case "${key}" in
    definition_of_excellent)
      value="${OMC_DEFINITION_OF_EXCELLENT:-}"
      case "${value}" in adaptive|always|off) printf '%s' "${value}" ;; *) return 1 ;; esac
      ;;
    quality_constitution)
      value="${OMC_QUALITY_CONSTITUTION:-}"
      case "${value}" in on|off) printf '%s' "${value}" ;; *) return 1 ;; esac
      ;;
    taste_learning)
      value="${OMC_TASTE_LEARNING:-}"
      case "${value}" in off|review|adaptive) printf '%s' "${value}" ;; *) return 1 ;; esac
      ;;
    quality_constitution_max_context_chars)
      value="${OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS:-}"
      [[ "${value}" =~ ^[1-9][0-9]*$ && "${value}" -le 12000 ]] || return 1
      printf '%s' "${value}"
      ;;
    *) model_env_override_value "${key}" ;;
  esac
}

warn_model_env_shadow() {
  local env_tier="" env_overrides=""
  env_tier="$(model_env_override_value model_tier 2>/dev/null || true)"
  env_overrides="$(model_env_override_value model_overrides 2>/dev/null || true)"
  if [[ -n "${env_tier}" || -n "${env_overrides}" ]]; then
    printf 'omc-config: WARNING: active OMC_MODEL_TIER/OMC_MODEL_OVERRIDES still govern this process at runtime. Saved config was materialized for persistent/direct-skill use; remove the environment override and start a new session to use the saved posture.\n' >&2
  fi
}

# Read a value with environment > allowed-project > user precedence, matching
# `load_conf` in common.sh. Denied project rows are deliberately invisible:
# the table reflects what the harness actually sees, not merely what a file
# contains.
read_effective_value() {
  local key="$1"
  local proj_conf proj_val user_val env_val
  if env_val="$(runtime_env_override_value "${key}")"; then
    printf '%s' "${env_val}"
    return 0
  fi
  if ! flag_is_project_denied "${key}" && proj_conf="$(find_project_conf)"; then
    proj_val="$(read_conf_value "${proj_conf}" "${key}")"
    if [[ -n "${proj_val}" ]]; then
      printf '%s' "${proj_val}"
      return 0
    fi
  fi
  user_val="$(read_effective_user_conf_value "${key}")"
  printf '%s' "${user_val}"
}

# Resolve the bundle's VERSION via the conf's repo_path. Only accepts the
# semver shape `MAJOR.MINOR.PATCH` (with optional `-prerelease`); anything
# else returns `unknown` so detect-mode never compares garbage against
# `installed_version` and lands in the wrong branch on a malformed file.
resolve_bundle_version() {
  local repo_path raw
  repo_path="$(read_conf_value "${USER_CONF}" repo_path)"
  if [[ -n "${repo_path}" && -f "${repo_path}/VERSION" ]]; then
    raw="$(tr -d '[:space:]' < "${repo_path}/VERSION")"
    if [[ "${raw}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
      printf '%s' "${raw}"
      return 0
    fi
  fi
  printf 'unknown'
}

# Validate one key=value pair against the KNOWN_FLAGS table.
# Exits the script on failure (preserves atomic-write semantics —
# no partial conf writes when an apply-preset has one bad value).
validate_kv() {
  local kv="$1"
  if [[ "${kv}" != *"="* ]]; then
    printf 'omc-config: malformed pair (no =): %s\n' "${kv}" >&2
    return 2
  fi
  local key="${kv%%=*}"
  local value="${kv#*=}"

  local flag_type=""
  local found=false
  local name typ
  while IFS='|' read -r name typ _default _category _desc; do
    [[ -z "${name}" ]] && continue
    if [[ "${name}" == "${key}" ]]; then
      flag_type="${typ}"
      found=true
      break
    fi
  done < <(emit_known_flags)

  if [[ "${found}" != "true" ]]; then
    printf 'omc-config: unknown flag: %s\n' "${key}" >&2
    return 2
  fi

  case "${flag_type}" in
    bool)
      if [[ ! "${value}" =~ ^(on|off)$ ]]; then
        printf 'omc-config: %s must be on|off (got: %s)\n' "${key}" "${value}" >&2
        return 2
      fi
      ;;
    true_false)
      if [[ ! "${value}" =~ ^(true|false)$ ]]; then
        printf 'omc-config: %s must be true|false (got: %s)\n' "${key}" "${value}" >&2
        return 2
      fi
      ;;
    int)
      if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
        printf 'omc-config: %s must be a non-negative integer (got: %s)\n' "${key}" "${value}" >&2
        return 2
      fi
      ;;
    pint)
      # Positive integer (>= 1). Use this for retention windows / TTLs
      # where 0 would silently be rejected by common.sh's parser regex
      # (^[1-9][0-9]*$) and the user would get the default instead — a
      # silent-fallback footgun the strict validator prevents.
      if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
        printf 'omc-config: %s must be a positive integer (got: %s)\n' "${key}" "${value}" >&2
        return 2
      fi
      if [[ "${key}" == "quality_constitution_max_context_chars" ]] \
          && (( value > 12000 )); then
        printf 'omc-config: %s must be at most 12000 (got: %s)\n' \
          "${key}" "${value}" >&2
        return 2
      fi
      ;;
    enum:*)
      local raw="${flag_type#enum:}"
      local pattern="^(${raw//\//|})$"
      if [[ ! "${value}" =~ ${pattern} ]]; then
        printf 'omc-config: %s must be one of %s (got: %s)\n' "${key}" "${raw}" "${value}" >&2
        return 2
      fi
      ;;
    str)
      # Free-form values still must not contain control chars — a value
      # carrying a literal newline would smuggle a second `key=value` line
      # into the conf at write time, bypassing validation entirely. This
      # is the conf-equivalent of CRLF injection.
      if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
        printf 'omc-config: %s value cannot contain newlines or carriage returns\n' "${key}" >&2
        return 2
      fi
      # v1.32.16 (4-attacker security review, A2-LOW-5): claude_bin
      # carries a path that the resume-watchdog later execs. The
      # conf parser at common.sh:382 enforces `^/` (absolute path);
      # apply the same constraint at write time so the omc-config
      # writer never lands a value the parser will silently drop.
      # Pre-fix divergence: `omc-config set user claude_bin=relative`
      # would write the line (parser later silently ignores), causing
      # an audit confusion where the user thinks the pin is set but
      # the watchdog uses live `command -v claude` instead.
      #
      # Path-prefix denylist mirrors the post-load common.sh block
      # (rejects `/tmp/`, `/var/tmp/`, `/Users/Shared/`, `/dev/shm/`,
      # `/private/tmp/`) so an attacker who tries to write a hostile
      # pin through omc-config gets blocked at write time too.
      if [[ "${key}" == "claude_bin" && -n "${value}" ]]; then
        if [[ ! "${value}" =~ ^/ ]]; then
          printf 'omc-config: claude_bin must be an absolute path (^/), got: %s\n' "${value}" >&2
          return 2
        fi
        case "${value}" in
          /tmp/*|/private/tmp/*|/var/tmp/*|/Users/Shared/*|/dev/shm/*)
            printf 'omc-config: claude_bin under world-writable / shared location is rejected: %s\n' "${value}" >&2
            return 2
            ;;
        esac
      fi
      if [[ "${key}" == "model_overrides" ]] \
          && ! model_overrides_value_is_valid "${value}"; then
        printf 'omc-config: model_overrides must be empty or comma-separated agent:model pins; agent is a bare or one-colon namespaced id, model is opus|sonnet|haiku|inherit, and inherit requires a bare materializable agent (got: %s)\n' \
          "${value}" >&2
        return 2
      fi
      ;;
  esac
  return 0
}

# Atomic multi-key conf write. Strips any prior occurrence of each key
# (last-write-wins semantics matching install.sh) and appends the new
# values in a single tmp file, then rename-replaces the conf.
#
# Within-batch dedup: when the same key appears multiple times in the
# argument list (e.g. `set user gate_level=full gate_level=basic`), only
# the LAST occurrence is appended. Without this, repeated invocations
# would accumulate dead lines in the conf even though the parser's
# `tail -1` resolution masks the user impact.
#
# tmp filename uses both `$$` and `$RANDOM` so two concurrent invocations
# from background-spawned shells with identical PIDs (rare but possible)
# do not race for the same scratch file. Last-mv-wins is still the outer
# concurrency model — the helper assumes single-writer and the skill is
# interactive, so writers do not contend in practice.
write_conf_atomic() {
  local conf="$1"
  shift
  mkdir -p "$(dirname "${conf}")"
  local tmp
  tmp="${conf}.tmp.$$.${RANDOM}"

  # Walk args, keeping the LAST kv per key. Bash 3-compat (no associative
  # arrays — macOS ships /bin/bash 3.2). Order of preserved keys follows
  # last-occurrence insertion order so the conf stays reasonable to read.
  local -a deduped_keys=()
  local -a deduped_values=()
  local kv key value i found
  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    found=-1
    for ((i = 0; i < ${#deduped_keys[@]}; i++)); do
      if [[ "${deduped_keys[$i]}" == "${key}" ]]; then
        found=$i
        break
      fi
    done
    if [[ $found -ge 0 ]]; then
      deduped_values[$found]="${value}"
    else
      deduped_keys+=( "${key}" )
      deduped_values+=( "${value}" )
    fi
  done

  local strip_pattern=""
  local k
  for k in "${deduped_keys[@]}"; do
    if [[ -z "${strip_pattern}" ]]; then
      strip_pattern="^${k}="
    else
      strip_pattern="${strip_pattern}|^${k}="
    fi
  done

  if [[ -f "${conf}" ]]; then
    grep -vE "${strip_pattern}" "${conf}" > "${tmp}" 2>/dev/null || true
  else
    : > "${tmp}"
  fi

  for ((i = 0; i < ${#deduped_keys[@]}; i++)); do
    printf '%s=%s\n' "${deduped_keys[$i]}" "${deduped_values[$i]}" >> "${tmp}"
  done

  mv "${tmp}" "${conf}"
}

# Resolve scope label to a conf path. Refuses unknown scopes.
resolve_scope_conf() {
  local scope="$1"
  case "${scope}" in
    user)    printf '%s' "${USER_CONF}" ;;
    project) get_project_conf ;;
    *)
      printf 'omc-config: unknown scope: %s (expected user|project)\n' "${scope}" >&2
      return 2 ;;
  esac
}

# --- Subcommands ---

cmd_detect_mode() {
  if [[ ! -f "${USER_CONF}" ]]; then
    printf 'not-installed\n'
    return 0
  fi
  local installed_v
  installed_v="$(read_conf_value "${USER_CONF}" installed_version)"
  if [[ -z "${installed_v}" ]]; then
    printf 'not-installed\n'
    return 0
  fi

  local completed
  completed="$(read_conf_value "${USER_CONF}" "${SENTINEL_KEY}")"
  if [[ -z "${completed}" ]]; then
    printf 'setup\n'
    return 0
  fi

  local bundle_v
  bundle_v="$(resolve_bundle_version)"
  if [[ -n "${bundle_v}" && "${bundle_v}" != "unknown" && "${bundle_v}" != "${installed_v}" ]]; then
    local first
    first="$(printf '%s\n%s\n' "${installed_v}" "${bundle_v}" | sort -V | head -1)"
    if [[ "${first}" == "${installed_v}" ]]; then
      printf 'update\n'
      return 0
    fi
  fi
  printf 'change\n'
}

cmd_show() {
  local installed_v bundle_v conf_marker="" proj_conf=""
  installed_v="$(read_conf_value "${USER_CONF}" installed_version)"
  bundle_v="$(resolve_bundle_version)"
  [[ -f "${USER_CONF}" ]] || conf_marker=" (missing)"
  proj_conf="$(find_project_conf || true)"

  printf 'oh-my-claude config\n'
  printf '  user conf:    %s%s\n' "${USER_CONF}" "${conf_marker}"
  if [[ -n "${proj_conf}" ]]; then
    printf '  project conf: %s (overrides user except user-only flags)\n' "${proj_conf}"
    local ignored_project_flags="" denied_flag
    for denied_flag in "${PROJECT_DENIED_FLAGS[@]}"; do
      if [[ -n "$(read_conf_value "${proj_conf}" "${denied_flag}")" ]]; then
        ignored_project_flags="${ignored_project_flags}${ignored_project_flags:+,}${denied_flag}"
      fi
    done
    if [[ -n "${ignored_project_flags}" ]]; then
      printf '  ! ignored project entries for user-only flags: %s\n' "${ignored_project_flags}"
    fi
    if [[ "${ignored_project_flags}" == *model_tier* ]] \
        || [[ "${ignored_project_flags}" == *model_overrides* ]]; then
      printf '  ! project model_tier/model_overrides entries are ignored; model strength and cost remain user-controlled.\n'
    fi
  fi
  if [[ -n "${OMC_MODEL_TIER:-}" ]] \
      && [[ ! "${OMC_MODEL_TIER}" =~ ^(quality|balanced|economy)$ ]]; then
    printf '  ! invalid OMC_MODEL_TIER=%s is ignored; saved user tier or the balanced default remains effective.\n' \
      "${OMC_MODEL_TIER}"
  fi
  if [[ -n "${OMC_MODEL_OVERRIDES:-}" ]] \
      && model_overrides_have_invalid_entries "${OMC_MODEL_OVERRIDES}"; then
    local valid_env_overrides=""
    valid_env_overrides="$(valid_model_overrides_summary \
      "${OMC_MODEL_OVERRIDES}")"
    if [[ -n "${valid_env_overrides}" ]]; then
      printf '  ! OMC_MODEL_OVERRIDES contains invalid entries; rejected pairs are ignored and only the accepted environment pins govern.\n'
    else
      printf '  ! OMC_MODEL_OVERRIDES contains no valid pins and is ignored; saved user pins remain effective.\n'
    fi
  fi
  local saved_model_tier_raw saved_model_overrides_raw valid_saved_overrides
  saved_model_tier_raw="$(read_conf_value "${USER_CONF}" model_tier)"
  if [[ -n "${saved_model_tier_raw}" ]] \
      && [[ ! "${saved_model_tier_raw}" =~ ^(quality|balanced|economy)$ ]]; then
    printf '  ! saved model_tier=%s is invalid and ignored; a valid environment tier or the balanced default remains effective.\n' \
      "${saved_model_tier_raw}"
  fi
  saved_model_overrides_raw="$(read_conf_value \
    "${USER_CONF}" model_overrides)"
  if [[ -n "${saved_model_overrides_raw}" ]] \
      && model_overrides_have_invalid_entries "${saved_model_overrides_raw}"; then
    valid_saved_overrides="$(valid_model_overrides_summary \
      "${saved_model_overrides_raw}")"
    if [[ -n "${valid_saved_overrides}" ]]; then
      printf '  ! saved model_overrides contains invalid entries; rejected pairs are ignored by the live resolver.\n'
    else
      printf '  ! saved model_overrides contains no valid pins and is ignored by the live resolver.\n'
    fi
  fi
  printf '  installed:    %s\n' "${installed_v:-unknown}"
  printf '  bundle:       %s\n' "${bundle_v:-unknown}"
  if [[ -n "${installed_v}" && -n "${bundle_v}" && "${bundle_v}" != "unknown" && "${bundle_v}" != "${installed_v}" ]]; then
    printf '  ! bundle differs from installed — run install.sh in the source repo to sync.\n'
  fi
  printf '\n'
  printf '  %-32s %-10s %-10s  %s\n' "FLAG" "VALUE" "DEFAULT" "DESCRIPTION"
  printf '  %-32s %-10s %-10s  %s\n' "----" "-----" "-------" "-----------"

  local prev_category=""
  local name flag_type default category desc
  while IFS='|' read -r name flag_type default category desc; do
    [[ -z "${name}" ]] && continue
    # Effective value uses environment>allowed-project>user>default
    # precedence (matches load_conf in common.sh).
    local val
    val="$(read_effective_value "${name}")"
    [[ -z "${val}" ]] && val="${default}"
    if [[ "${category}" != "${prev_category}" ]]; then
      printf '  -- %s --\n' "${category}"
      prev_category="${category}"
    fi
    # Build the source annotation so users can see which authority supplied
    # the effective value. Malformed tiers and wholly invalid override sets are
    # ignored; mixed override sets retain [E] precedence for their valid subset.
    local marker="  " source_tag=""
    if runtime_env_override_value "${name}" >/dev/null 2>&1; then
      source_tag=" [E]"
    elif [[ -n "${proj_conf}" ]] \
        && ! flag_is_project_denied "${name}" \
        && [[ -n "$(read_conf_value "${proj_conf}" "${name}")" ]]; then
      source_tag=" [P]"
    elif [[ -n "$(read_effective_user_conf_value "${name}")" ]]; then
      source_tag=" [U]"
    fi
    if [[ -n "${val}" && "${val}" != "${default}" ]]; then
      marker="* "
    fi
    printf '  %s%-30s %-10s %-10s  %s%s\n' "${marker}" "${name}" "${val:-(unset)}" "${default:-(none)}" "${desc}" "${source_tag}"
  done < <(emit_known_flags)

  printf '\n  Marked * = differs from default.'
  local has_effective_env=0
  if runtime_env_override_value model_tier >/dev/null 2>&1 \
      || runtime_env_override_value model_overrides >/dev/null 2>&1 \
      || runtime_env_override_value definition_of_excellent >/dev/null 2>&1 \
      || runtime_env_override_value quality_constitution >/dev/null 2>&1 \
      || runtime_env_override_value taste_learning >/dev/null 2>&1 \
      || runtime_env_override_value quality_constitution_max_context_chars >/dev/null 2>&1; then
    has_effective_env=1
  fi
  if (( has_effective_env == 1 )) && [[ -n "${proj_conf}" ]]; then
    printf '   [E]=environment override, [P]=project override, [U]=user setting'
  elif (( has_effective_env == 1 )); then
    printf '   [E]=environment override, [U]=user setting'
  elif [[ -n "${proj_conf}" ]]; then
    printf '   [P]=project override, [U]=user setting'
  fi
  printf '\n'
}

cmd_list_flags_json() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'omc-config: jq is required for list-flags --json\n' >&2
    return 1
  fi
  local out='[]'
  local name flag_type default category desc
  while IFS='|' read -r name flag_type default category desc; do
    [[ -z "${name}" ]] && continue
    local val
    val="$(read_effective_user_conf_value "${name}")"
    [[ -z "${val}" ]] && val="${default}"
    out="$(printf '%s' "${out}" | jq \
      --arg name "${name}" \
      --arg type "${flag_type}" \
      --arg default "${default}" \
      --arg category "${category}" \
      --arg desc "${desc}" \
      --arg current "${val}" \
      '. += [{name: $name, type: $type, default: $default, category: $category, description: $desc, current: $current}]')"
  done < <(emit_known_flags)
  printf '%s\n' "${out}"
}

cmd_set() {
  if [[ $# -lt 2 ]]; then
    printf 'omc-config: set requires <scope> and at least one key=value pair\n' >&2
    printf 'usage: omc-config.sh set <user|project> <k=v> [<k=v>...]\n' >&2
    return 2
  fi
  local scope="$1"
  shift
  local conf
  conf="$(resolve_scope_conf "${scope}")"

  # Validate all pairs first; commit only when every value is sound.
  local kv
  for kv in "$@"; do
    validate_kv "${kv}"
  done

  # A project-scoped write here would be worse than a no-op: common.sh would
  # ignore the line, while the historical model_tier side effect below could
  # still rewrite the machine-wide installed agent fallbacks. Reject the whole
  # batch before touching either config or agent files.
  if [[ "${scope}" == "project" ]]; then
    for kv in "$@"; do
      if flag_is_project_denied "${kv%%=*}"; then
        if flag_is_model_user_only "${kv%%=*}"; then
          printf 'omc-config: %s is user-only; use `set user %s` (project config cannot choose model strength or cost)\n' \
            "${kv%%=*}" "${kv}" >&2
        else
          printf 'omc-config: %s is user-only and ignored by project config; use `set user %s`\n' \
            "${kv%%=*}" "${kv}" >&2
        fi
        return 2
      fi
    done
  fi

  # Mirror `apply-preset`'s defense-in-depth for both halves of model config.
  # A tier change must rewrite declarations, and an override-only change must
  # reapply the current tier so direct-skill frontmatter matches the live ULW
  # resolver immediately. One switch call handles a batch that changes both.
  local prior_tier="" new_tier=""
  local prior_overrides="" new_overrides="" has_new_overrides=0
  local overrides_changed=0
  local prior_style="" new_style=""
  for kv in "$@"; do
    case "${kv%%=*}" in
      model_tier) new_tier="${kv#*=}" ;;
      model_overrides)
        new_overrides="${kv#*=}"
        has_new_overrides=1
        ;;
      output_style) new_style="${kv#*=}" ;;
    esac
  done
  if [[ -n "${new_tier}" ]]; then
    prior_tier="$(read_conf_value "${conf}" model_tier)"
  fi
  if [[ -n "${new_style}" ]]; then
    prior_style="$(read_conf_value "${conf}" output_style)"
  fi
  if (( has_new_overrides == 1 )); then
    prior_overrides="$(read_conf_value "${conf}" model_overrides)"
    if [[ "${new_overrides}" != "${prior_overrides}" ]]; then
      overrides_changed=1
    fi
  fi

  write_conf_atomic "${conf}" "$@"
  printf 'omc-config: wrote %d key(s) to %s\n' "$#" "${conf}"

  local model_apply_tier="" model_apply_reason=""
  if [[ -n "${new_tier}" && "${new_tier}" != "${prior_tier}" ]]; then
    printf 'omc-config: model_tier changed (%s -> %s); rewriting agents...\n' \
      "${prior_tier:-unset}" "${new_tier}"
    model_apply_tier="${new_tier}"
    model_apply_reason="tier"
  elif (( overrides_changed == 1 )); then
    model_apply_tier="$(read_conf_value "${USER_CONF}" model_tier)"
    case "${model_apply_tier}" in
      quality|balanced|economy) ;;
      *) model_apply_tier="balanced" ;;
    esac
    model_apply_reason="overrides"
    printf 'omc-config: model_overrides changed; reapplying %s tier to direct-skill agent fallbacks...\n' \
      "${model_apply_tier}"
  fi

  if [[ -n "${model_apply_tier}" ]]; then
    # A changed quality override can leave an old pin indistinguishable from
    # the tier's own materialized frontmatter (oracle:opus, librarian:haiku,
    # etc.). The switcher reconstructs both shipped declaration classes on
    # every tier, so Economy also repairs legacy flattened installs before
    # pins are reapplied. --force-reconstruct remains a compatibility signal
    # for older installed switchers on Quality transitions.
    local force_reconstruct=0
    if [[ "${model_apply_tier}" == "quality" ]]; then
      if (( overrides_changed == 1 )) || [[ "${prior_tier}" == "economy" ]]; then
        force_reconstruct=1
      fi
    fi
    if [[ -x "${HOME}/.claude/switch-tier.sh" ]]; then
      cmd_apply_saved_tier "${model_apply_tier}" "${force_reconstruct}" || {
        printf 'omc-config: WARNING: apply-tier failed after model %s change; saved config was written, but agent files and live routing may be out of sync. An inherit pin is active only when its bare definition already says inherit; repair the switcher and rerun this tier to materialize shipped pins.\n' \
          "${model_apply_reason}" >&2
        if (( force_reconstruct == 1 )); then
          printf 'omc-config: Restore or reinstall ~/.claude/switch-tier.sh, then rerun the saved tier; its embedded rosters reconstruct canonical declarations without the source clone.\n' >&2
        fi
      }
      warn_model_env_shadow
    else
      if (( force_reconstruct == 1 )); then
        printf 'omc-config: WARNING: switch-tier.sh is missing; saved config was written, but an inherit pin is active only when its bare definition already says inherit. Reinstall the switcher, then rerun the saved tier to reconstruct canonical declarations and materialize the current quality overrides.\n' >&2
      else
        printf 'omc-config: WARNING: switch-tier.sh not installed; saved config was written, but an inherit pin is active only when its bare definition already says inherit. Reinstall it, then run `bash %s/.claude/switch-tier.sh %s` manually\n' \
          "${HOME}" "${model_apply_tier}" >&2
      fi
    fi
  fi

  # v1.31.0 Wave 6 (design-lens F-028): auto-sync settings.json when
  # output_style changes via /omc-config. Pre-Wave-6 the conf flag
  # was written but settings.json was untouched until the next
  # `bash install.sh` run — users picked "executive" and got the old
  # voice the rest of the session, with no signal that a reinstall
  # was required. The sync flips the bundled-style name in
  # settings.json without disturbing user-set custom styles (matches
  # install.sh's "preserve user-set styles" rule).
  if [[ -n "${new_style}" && "${new_style}" != "${prior_style}" ]]; then
    sync_output_style_settings "${new_style}" || \
      printf 'omc-config: WARNING: output_style sync to settings.json failed; run `bash ~/.claude/install.sh` manually\n' >&2
  fi
}

# v1.31.0 Wave 6 (design-lens F-028): write settings.json's
# outputStyle field from a known conf value. Mirrors install.sh's
# logic: only auto-syncs when the existing setting is null or one of
# the bundled style names. User-set custom styles are preserved.
# Returns 0 on success, non-zero on failure (caller logs warning).
sync_output_style_settings() {
  local pref="$1"
  local target_style=""
  case "${pref}" in
    opencode)  target_style="oh-my-claude" ;;
    executive) target_style="executive-brief" ;;
    preserve)  return 0 ;;  # explicit no-op
    *) return 1 ;;
  esac

  local settings_file="${HOME}/.claude/settings.json"
  if [[ ! -f "${settings_file}" ]]; then
    return 0  # no settings.json yet — install.sh will create it
  fi

  local tmp
  tmp="$(mktemp "${settings_file}.tmp.XXXXXX")" || return 1
  local _BUNDLED='oh-my-claude|executive-brief|OpenCode Compact'
  if jq --arg target "${target_style}" --arg bundled "${_BUNDLED}" '
      . as $orig
      | (.outputStyle // null) as $cur
      | if ($cur == null) or (($cur | type) == "string" and (($cur | test("^(" + $bundled + ")$")) or ($cur == "")))
        then .outputStyle = $target
        else .
        end
    ' "${settings_file}" > "${tmp}" 2>/dev/null; then
    if mv -f "${tmp}" "${settings_file}"; then
      printf 'omc-config: settings.json outputStyle synced to %s\n' "${target_style}"
      return 0
    fi
  fi
  rm -f "${tmp}" 2>/dev/null
  return 1
}

cmd_apply_preset() {
  if [[ $# -ne 2 ]]; then
    printf 'omc-config: apply-preset requires <scope> <profile>\n' >&2
    printf 'usage: omc-config.sh apply-preset <user|project> <maximum|zero-steering|balanced|minimal>\n' >&2
    return 2
  fi
  local scope="$1" profile="$2"
  local conf
  conf="$(resolve_scope_conf "${scope}")"

  local pairs=()
  local omitted_user_only=()
  local line key
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    key="${line%%=*}"
    if [[ "${scope}" == "project" ]] && flag_is_project_denied "${key}"; then
      omitted_user_only+=( "${key}" )
      continue
    fi
    pairs+=( "${line}" )
  done < <(emit_preset "${profile}")

  if [[ ${#pairs[@]} -eq 0 ]]; then
    printf 'omc-config: preset %s produced no entries\n' "${profile}" >&2
    return 2
  fi

  local kv
  for kv in "${pairs[@]}"; do
    validate_kv "${kv}"
  done

  # Capture the prior model_tier (from the same scope's conf) BEFORE the
  # write so we can detect whether the preset is changing the tier. If it
  # is, the helper invokes `apply-tier` itself — defense-in-depth for the
  # case where the SKILL flow's "Step 5a — invoke apply-tier when tier
  # changed" instruction is skipped. Without this, the conf could claim
  # `model_tier=quality` while every agent file still says `sonnet`.
  local prior_tier new_tier
  prior_tier="$(read_conf_value "${conf}" model_tier)"
  new_tier=""
  for kv in "${pairs[@]}"; do
    if [[ "${kv%%=*}" == "model_tier" ]]; then
      new_tier="${kv#*=}"
      break
    fi
  done

  write_conf_atomic "${conf}" "${pairs[@]}"
  printf 'omc-config: applied preset "%s" (%d keys) to %s\n' "${profile}" "${#pairs[@]}" "${conf}"
  if [[ ${#omitted_user_only[@]} -gt 0 ]]; then
    printf 'omc-config: project scope preserved user-wide restricted settings; omitted user-only preset key(s): %s\n' \
      "$(IFS=,; printf '%s' "${omitted_user_only[*]}")"
    if printf '%s\n' "${omitted_user_only[@]}" | grep -qE '^model_(tier|overrides)$'; then
      printf 'omc-config: model strength and cost are unchanged at the active user/environment setting.\n'
    fi
  fi

  # Auto-fire the agent-file rewrite when the tier changed. Skip when
  # unchanged or when the switcher is missing (apply-tier surfaces its
  # own error in that case). Best-effort — preset write already
  # succeeded; a switcher failure here should warn but not unwind.
  if [[ -n "${new_tier}" && "${new_tier}" != "${prior_tier}" ]]; then
    printf 'omc-config: model_tier changed (%s -> %s); rewriting agents...\n' \
      "${prior_tier:-unset}" "${new_tier}"
    if [[ -x "${HOME}/.claude/switch-tier.sh" ]]; then
      # The preset write above has already changed conf, so switch-tier cannot
      # infer the old materialized tier from disk. Economy erased the shipped
      # inherit split, and a surviving `agent:inherit` override can otherwise
      # make the new Quality state look canonical. Pass the captured prior tier
      # through as an explicit reconstruction decision.
      local force_reconstruct=0
      if [[ "${new_tier}" == "quality" && "${prior_tier}" == "economy" ]]; then
        force_reconstruct=1
      fi
      cmd_apply_saved_tier "${new_tier}" "${force_reconstruct}" || \
        printf 'omc-config: WARNING: apply-tier failed; agent files may be out of sync with conf\n' >&2
      warn_model_env_shadow
    else
      printf 'omc-config: WARNING: switch-tier.sh not installed; run `bash %s/.claude/switch-tier.sh %s` manually\n' \
        "${HOME}" "${new_tier}" >&2
    fi
  fi
}

cmd_mark_completed() {
  # Sentinel is "this user has been through the wizard once" — a
  # per-machine flag, not per-project. `detect-mode` only reads
  # USER_CONF for this key, so writing it to the project conf would
  # leave the user stuck in `setup` mode forever. Ignore any scope
  # argument and always stamp USER_CONF; the scope arg is preserved
  # for backward-compat with callers that pass it (the SKILL flow did
  # before the fix landed) but the scope no longer changes the path.
  local _scope_ignored="${1:-user}"
  local stamp
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_conf_atomic "${USER_CONF}" "${SENTINEL_KEY}=${stamp}"
  printf 'omc-config: stamped %s=%s in %s (always user scope)\n' \
    "${SENTINEL_KEY}" "${stamp}" "${USER_CONF}"
}

cmd_apply_tier() {
  local tier="${1:-}"
  local force_reconstruct="${2:-0}"
  if [[ -z "${tier}" ]]; then
    printf 'omc-config: apply-tier requires <quality|balanced|economy>\n' >&2
    return 2
  fi
  if [[ ! "${tier}" =~ ^(quality|balanced|economy)$ ]]; then
    printf 'omc-config: tier must be quality|balanced|economy (got: %s)\n' "${tier}" >&2
    return 2
  fi
  case "${force_reconstruct}" in
    0|1) ;;
    *)
      printf 'omc-config: internal force-reconstruct value must be 0|1 (got: %s)\n' \
        "${force_reconstruct}" >&2
      return 2
      ;;
  esac
  local switcher="${HOME}/.claude/switch-tier.sh"
  if [[ ! -x "${switcher}" ]]; then
    printf 'omc-config: switch-tier.sh not found at %s\n' "${switcher}" >&2
    printf '            Re-run install.sh to refresh the bundle, then retry.\n' >&2
    return 1
  fi
  if [[ "${force_reconstruct}" == "1" ]]; then
    bash "${switcher}" "${tier}" --force-reconstruct
  else
    bash "${switcher}" "${tier}"
  fi
}

# Persistent `set user` / user-preset writes materialize the value just saved
# to disk. A launch-time environment override still governs live routing, but
# must not silently rewrite direct-skill frontmatter to a different value than
# the persistent config the user requested.
cmd_apply_saved_tier() {
  (
    unset OMC_MODEL_TIER OMC_MODEL_OVERRIDES
    cmd_apply_tier "$@"
  )
}

cmd_install_watchdog() {
  local installer="${HOME}/.claude/install-resume-watchdog.sh"
  if [[ ! -x "${installer}" ]]; then
    printf 'omc-config: watchdog installer not found at %s\n' "${installer}" >&2
    printf '            Re-run install.sh to refresh the bundle, then retry.\n' >&2
    return 1
  fi
  bash "${installer}"
}

usage() {
  cat <<'EOF'
omc-config.sh — backend for /omc-config skill.

Subcommands:
  detect-mode                          Print setup|update|change|not-installed
  show                                 Pretty-print current effective config
  list-flags                           Emit known flags as JSON (for skill)
  set <user|project> <k=v>...          Atomic write of one or more keys
  apply-preset <user|project> <name>   Apply preset (maximum|zero-steering|balanced|minimal)
  presets <name>                       Print preset key=value pairs to stdout
  apply-tier <quality|balanced|economy>  Run switch-tier.sh (rewrites agent files)
  install-watchdog                     Run install-resume-watchdog.sh
  mark-completed [user|project]        Stamp omc_config_completed=<ISO date>

Conventions:
  user scope    -> ~/.claude/oh-my-claude.conf
  project scope -> $(pwd)/.claude/oh-my-claude.conf
                   (security/persistence/model authority flags are user-only)

Exit codes:
  0 success | 1 runtime failure | 2 invalid invocation
EOF
}

main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    detect-mode)      cmd_detect_mode ;;
    show)             cmd_show ;;
    list-flags)       cmd_list_flags_json ;;
    set)              cmd_set "$@" ;;
    apply-preset)     cmd_apply_preset "$@" ;;
    presets)          emit_preset "${1:-}" ;;
    apply-tier)       cmd_apply_tier "${1:-}" ;;
    install-watchdog) cmd_install_watchdog ;;
    mark-completed)   cmd_mark_completed "$@" ;;
    ""|-h|--help)     usage ;;
    *)
      printf 'omc-config: unknown subcommand: %s\n' "${cmd}" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
