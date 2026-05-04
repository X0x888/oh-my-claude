#!/usr/bin/env bash

set -euo pipefail

STATE_ROOT="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"
STATE_JSON="session_state.json"
HOOK_LOG="${STATE_ROOT}/hooks.log"

# Restrict file permissions for all state files, temp files, and logs.
# Session state contains user prompts and assistant messages — keep
# them owner-readable only, especially on shared systems.
umask 077

# Guard: jq is required for all hook operations. If missing, exit gracefully
# so hooks don't break Claude Code's operation.
if ! command -v jq >/dev/null 2>&1; then
  printf 'oh-my-claude: jq is required but not found in PATH. Hooks disabled.\n' >&2
  exit 0
fi

# --- Configurable thresholds (tunable via oh-my-claude.conf) ---
# Precedence: env var > conf file > built-in default.
# Track which vars were set via env before applying defaults.
_omc_env_stall="${OMC_STALL_THRESHOLD:-}"
_omc_env_excellence="${OMC_EXCELLENCE_FILE_COUNT:-}"
_omc_env_ttl="${OMC_STATE_TTL_DAYS:-}"
_omc_env_dimgate="${OMC_DIMENSION_GATE_FILE_COUNT:-}"
_omc_env_traceability="${OMC_TRACEABILITY_FILE_COUNT:-}"
_omc_env_exhaustion="${OMC_GUARD_EXHAUSTION_MODE:-}"
_omc_env_verify_conf="${OMC_VERIFY_CONFIDENCE_THRESHOLD:-}"
_omc_env_gate_level="${OMC_GATE_LEVEL:-}"
_omc_env_verify_mcp="${OMC_CUSTOM_VERIFY_MCP_TOOLS:-}"
_omc_env_pretool_intent="${OMC_PRETOOL_INTENT_GUARD:-}"
_omc_env_classifier_tel="${OMC_CLASSIFIER_TELEMETRY:-}"
_omc_env_discovered_scope="${OMC_DISCOVERED_SCOPE:-}"
_omc_env_council_deep_default="${OMC_COUNCIL_DEEP_DEFAULT:-}"
_omc_env_auto_memory="${OMC_AUTO_MEMORY:-}"
_omc_env_output_style="${OMC_OUTPUT_STYLE:-}"
_omc_env_metis_on_plan_gate="${OMC_METIS_ON_PLAN_GATE:-}"
_omc_env_prometheus_suggest="${OMC_PROMETHEUS_SUGGEST:-}"
_omc_env_intent_verify_directive="${OMC_INTENT_VERIFY_DIRECTIVE:-}"
_omc_env_exemplifying_directive="${OMC_EXEMPLIFYING_DIRECTIVE:-}"
_omc_env_exemplifying_scope_gate="${OMC_EXEMPLIFYING_SCOPE_GATE:-}"
_omc_env_prompt_text_override="${OMC_PROMPT_TEXT_OVERRIDE:-}"
_omc_env_mark_deferred_strict="${OMC_MARK_DEFERRED_STRICT:-}"
_omc_env_wave_override_ttl="${OMC_WAVE_OVERRIDE_TTL_SECONDS:-}"
_omc_env_stop_failure_capture="${OMC_STOP_FAILURE_CAPTURE:-}"
_omc_env_prompt_persist="${OMC_PROMPT_PERSIST:-}"
_omc_env_resume_request_ttl="${OMC_RESUME_REQUEST_TTL_DAYS:-}"
_omc_env_resume_watchdog="${OMC_RESUME_WATCHDOG:-}"
_omc_env_resume_watchdog_cooldown="${OMC_RESUME_WATCHDOG_COOLDOWN_SECS:-}"
_omc_env_time_tracking="${OMC_TIME_TRACKING:-}"
_omc_env_time_tracking_xs_retain="${OMC_TIME_TRACKING_XS_RETAIN_DAYS:-}"
_omc_env_time_card_min_seconds="${OMC_TIME_CARD_MIN_SECONDS:-}"
_omc_env_model_drift_canary="${OMC_MODEL_DRIFT_CANARY:-}"
_omc_env_blindspot_inventory="${OMC_BLINDSPOT_INVENTORY:-}"
_omc_env_intent_broadening="${OMC_INTENT_BROADENING:-}"
_omc_env_blindspot_ttl="${OMC_BLINDSPOT_TTL_SECONDS:-}"
_omc_env_claude_bin="${OMC_CLAUDE_BIN:-}"
_omc_env_resume_request_per_cwd_cap="${OMC_RESUME_REQUEST_PER_CWD_CAP:-}"

OMC_STALL_THRESHOLD="${OMC_STALL_THRESHOLD:-12}"
OMC_EXCELLENCE_FILE_COUNT="${OMC_EXCELLENCE_FILE_COUNT:-3}"
OMC_STATE_TTL_DAYS="${OMC_STATE_TTL_DAYS:-7}"
OMC_DIMENSION_GATE_FILE_COUNT="${OMC_DIMENSION_GATE_FILE_COUNT:-3}"
OMC_TRACEABILITY_FILE_COUNT="${OMC_TRACEABILITY_FILE_COUNT:-6}"
# Guard exhaustion mode: scorecard (default, legacy: warn), block (legacy: strict), silent (legacy: release)
OMC_GUARD_EXHAUSTION_MODE="${OMC_GUARD_EXHAUSTION_MODE:-scorecard}"
# Minimum verification confidence (0-100) to satisfy the verify gate.
# Default 40: blocks lint-only checks (shellcheck=30, bash -n=30) while
# accepting project test suites (npm test=70+) and framework runs (jest=50+).
OMC_VERIFY_CONFIDENCE_THRESHOLD="${OMC_VERIFY_CONFIDENCE_THRESHOLD:-40}"
# Gate level: basic (quality gate only), standard (+ excellence), full (+ dimensions)
OMC_GATE_LEVEL="${OMC_GATE_LEVEL:-full}"
# Pipe-separated glob patterns for additional MCP tools that count as verification.
# Example: mcp__my_cypress__*|mcp__custom_api_tester__*
# NOTE: Custom MCP tools also require a matching PostToolUse hook entry in
# settings.json to trigger record-verification.sh. The builtin matcher only
# covers Playwright and computer-use tools.
OMC_CUSTOM_VERIFY_MCP_TOOLS="${OMC_CUSTOM_VERIFY_MCP_TOOLS:-}"
# Pinned absolute path to the `claude` binary. Default empty = live
# `command -v claude` lookup at watchdog launch time (legacy behavior
# preserved). When set, the watchdog validates the pin via `${pinned}
# --version` (5s timeout if available) before each launch and falls
# back to live lookup on validation failure WITHOUT overwriting the
# pin (avoids pin-churn from transient PATH conditions like nvm
# switches). Auto-set by `install-resume-watchdog.sh` at install time.
OMC_CLAUDE_BIN="${OMC_CLAUDE_BIN:-}"
# Per-cwd cap on resume_request.json artifacts. Default 3: a user who hits
# 7 rate-limits in 7 days accumulates 7 artifacts otherwise. Set to 0 to
# disable the sweep (every artifact persists until age-out via
# resume_request_ttl_days). Producer-side enforcement: stop-failure-handler.sh
# sweeps after each new artifact write so the cap is atomic with capture.
OMC_RESUME_REQUEST_PER_CWD_CAP="${OMC_RESUME_REQUEST_PER_CWD_CAP:-3}"
# PreToolUse intent guard: when `true` (default), the guard denies destructive
# git/gh operations while task_intent is advisory/session-management/checkpoint.
# Set to `false` to disable enforcement and rely on the directive layer alone
# (e.g. for users who prefer the model to make its own judgement calls and
# accept the risk of the 2026-04-17-class incident).
OMC_PRETOOL_INTENT_GUARD="${OMC_PRETOOL_INTENT_GUARD:-true}"
# Wave-execution override TTL (seconds): freshness window for the
# `pretool-intent-guard.sh` wave-active exception. When a council Phase 8
# wave plan is active and its `updated_ts` is within this many seconds,
# the gate allows `git commit` even under non-execution intent. Stale
# plans (older than the TTL) do NOT trigger the override, so abandoned
# plans cannot leak per-wave authorization into unrelated later work.
# Default 1800s = 30 minutes; raise if your wave cycles legitimately
# exceed this between commits, lower to tighten.
OMC_WAVE_OVERRIDE_TTL_SECONDS="${OMC_WAVE_OVERRIDE_TTL_SECONDS:-1800}"
# Classifier telemetry capture: when `on` (default), every UserPromptSubmit
# records a row to `<session>/classifier_telemetry.jsonl` and the follow-up
# prompt's hook may annotate misfire rows. The prompt preview (first 200
# chars) is captured. Set to `off` to disable all recording — useful for
# shared machines, regulated codebases, or any context where writing user
# prompt previews to disk is unwanted. Cross-session aggregation at TTL
# sweep also becomes a no-op because per-session files won't exist.
OMC_CLASSIFIER_TELEMETRY="${OMC_CLASSIFIER_TELEMETRY:-on}"
# Discovered-scope tracking: when `on` (default), advisory specialists
# (council lenses, metis, briefing-analyst) have their findings extracted
# and recorded to `<session>/discovered_scope.jsonl`. Stop-guard then
# blocks a session that captured findings but stops without addressing
# or deferring each one. Set to `off` to disable both capture and gate
# (kill switch) — useful when heuristic extraction proves noisy on a
# specific project's prose style.
OMC_DISCOVERED_SCOPE="${OMC_DISCOVERED_SCOPE:-on}"
# Council deep-default: when `on`, auto-triggered council dispatches (via the
# prompt-intent-router's `is_council_evaluation_request` detection) inherit
# the equivalent of `/council --deep` — lens dispatches get `model: "opus"`
# instead of the default `sonnet`. Default is `off` because opus per-lens is
# meaningfully more expensive; quality-first users on `model_tier=quality`
# are the typical opt-in. Explicit `/council --deep` invocations are
# unaffected by this flag (they always escalate). Direct `/council` without
# `--deep` also remains unchanged — only the AUTO-detected dispatch path
# (broad project-evaluation prompts under /ulw) is affected.
OMC_COUNCIL_DEEP_DEFAULT="${OMC_COUNCIL_DEEP_DEFAULT:-off}"
# Auto-memory wrap-up: when `on` (default), the auto-memory.md and
# compact.md memory-sweep rules write project_*/feedback_*/user_*/
# reference_*.md files at session-stop and pre-compact moments. Set to
# `off` for shared machines, regulated codebases, or projects where
# session memory should not accrue across runs. Explicit user requests
# ("remember that...") still apply regardless of this flag.
OMC_AUTO_MEMORY="${OMC_AUTO_MEMORY:-on}"
# Bias-defense layer (v1.19.0): three opt-in mechanisms that target the
# bias-blindness gap (model confidently solves the wrong problem). All
# three default OFF so existing sessions see zero behavior change unless
# the user opts in. Together they form a soft-to-hard escalation:
# directives at prompt time → state writes at plan time → hard gate at
# stop time.
#
# metis_on_plan_gate: when `on`, stop-guard blocks Stop on a complex
# plan (≥5 steps, ≥3 files, ≥2 waves, or migration/refactor/schema/
# breaking keyword paired with non-trivial scope) until metis has run a
# stress-test review. Default off because the existing soft notice in
# record-plan.sh is sufficient for most users; opt in when you want the
# gate to enforce.
OMC_METIS_ON_PLAN_GATE="${OMC_METIS_ON_PLAN_GATE:-off}"
# prometheus_suggest: when `on`, the prompt-intent-router injects a
# declare-and-proceed directive on execution prompts that are short
# AND product-shaped (build/create/design + app/dashboard/feature, with
# no specific code anchors). The directive tells the model to state its
# scope interpretation in one or two declarative sentences as part of
# its opener and proceed — never to pause for confirmation. /prometheus
# is reserved for the credible-approach-split case (two interpretations
# credibly incompatible AND choosing wrong would cost rework). Default
# off to avoid false-positive grief on prompts the user knew they
# wanted to drive directly. (Reframed v1.24.0 — the prior wording told
# the model to ask for confirmation before editing, which produced a
# ULW-incompatible hold; the directive is now an auditing aid, not a
# pause case.)
OMC_PROMETHEUS_SUGGEST="${OMC_PROMETHEUS_SUGGEST:-off}"
# intent_verify_directive: when `on`, the prompt-intent-router injects
# a declare-and-proceed directive telling the model to state its
# interpretation of the goal in one declarative sentence as part of
# its opener (e.g., "I'm interpreting this as <X> and proceeding now")
# and start work — never to pause for confirmation. Pause case is
# narrow: only stop when both confidence is low AND the wrong call
# would be hard to reverse (the credible-approach-split test from
# core.md). Lighter than prometheus — one declarative sentence vs two
# plus non-goals. Default off; suppressed when prometheus_suggest
# already fired on the same turn (no double-friction). (Reframed
# v1.24.0 — see prometheus_suggest note above for the same rationale.)
OMC_INTENT_VERIFY_DIRECTIVE="${OMC_INTENT_VERIFY_DIRECTIVE:-off}"
# exemplifying_directive (v1.23.0): when `on`, the prompt-intent-router
# injects an EXEMPLIFYING SCOPE DETECTED directive telling the model to
# treat user-exemplified scope as a class (enumerate sibling items)
# rather than as the literal example. Symmetric to prometheus/intent-
# verify but defends against the OPPOSITE bias — *under-commitment*
# (model interprets "for instance, X" as "implement only X"). Default
# ON because it's informational rather than blocking, and the failure
# mode it defends against was a primary v1.22.x complaint.
OMC_EXEMPLIFYING_DIRECTIVE="${OMC_EXEMPLIFYING_DIRECTIVE:-on}"
# exemplifying_scope_gate (post-v1.23.0): when `on`, fresh execution
# prompts that use example markers ("for instance", "e.g.", "such as",
# etc.) must leave behind a state-backed scope checklist before the
# session can stop. This turns the examples-as-classes rule from a
# soft directive into an auditable deliverable ledger: every sibling
# item must be shipped or explicitly declined with a concrete WHY.
OMC_EXEMPLIFYING_SCOPE_GATE="${OMC_EXEMPLIFYING_SCOPE_GATE:-on}"
# prompt_text_override (v1.23.0): when `on`, the PreTool intent guard
# permits a destructive op when the most recent user prompt
# unambiguously authorizes the verb being attempted, even if the
# classifier mis-routed the prompt as advisory. Defense-in-depth that
# closes the long-tail of imperative-tail prompt shapes the regex
# layer can't fully cover. Default ON because the failure mode it
# defends against (model parroting "reply with: ship the commit on
# <branch>") was the primary v1.22.x UX complaint.
OMC_PROMPT_TEXT_OVERRIDE="${OMC_PROMPT_TEXT_OVERRIDE:-on}"
# mark_deferred_strict (v1.23.0): when `on`, mark-deferred.sh rejects
# bare "out of scope" / "not in scope" / "follow-up" / "separate task"
# / "later" / "low priority" reasons that have historically been used
# as silent-skip escape hatches. Reasons must contain a WHY keyword
# (requires/blocked/superseded/awaiting/pending/etc.) OR be a self-
# explanatory single token from the allowlist (duplicate / obsolete
# / superseded / wontfix / invalid / not applicable / n/a / not a bug).
# Default ON because the user explicitly identified this as a notorious
# escape pattern in v1.22.x and earlier.
OMC_MARK_DEFERRED_STRICT="${OMC_MARK_DEFERRED_STRICT:-on}"
# Resume-request artifact lifetime: max age (days) for a `resume_request.json`
# to still be considered claimable. Older artifacts are treated as stale and
# silently ignored by the SessionStart resume hint and the watchdog. The
# parent state directory is itself swept by the OMC_STATE_TTL_DAYS sweep.
# Default 7 days — long enough for a 7-day rate-limit window plus a slack
# buffer, short enough that a crashed-and-forgotten resume from last month
# does not surprise the user when they re-open Claude Code in the project.
OMC_RESUME_REQUEST_TTL_DAYS="${OMC_RESUME_REQUEST_TTL_DAYS:-7}"
# Wave 3 — headless resume watchdog. Default OFF — the daemon launches
# `claude --resume` on the user's behalf when a rate-limit window
# clears, which is meaningful behavior change requiring opt-in. Enable
# via `resume_watchdog=on` in oh-my-claude.conf or env
# OMC_RESUME_WATCHDOG=on, then run install-resume-watchdog.sh to
# register the LaunchAgent (macOS) / systemd user-timer (Linux) /
# cron one-liner (fallback). Privacy: also gated by
# is_stop_failure_capture_enabled — if the producer is disabled, the
# watchdog has nothing to do.
OMC_RESUME_WATCHDOG="${OMC_RESUME_WATCHDOG:-off}"
# Per-artifact cooldown between watchdog launch attempts. Default 600s
# (10min): long enough for `claude --resume` to either succeed or
# definitively fail; short enough to retry within a typical rate-limit
# window. Combined with the helper's 3-attempt cap, this caps total
# retry effort at ~30 minutes per artifact before surrendering.
OMC_RESUME_WATCHDOG_COOLDOWN_SECS="${OMC_RESUME_WATCHDOG_COOLDOWN_SECS:-600}"
# Time-tracking — captures per-tool / per-subagent durations into
# `<session>/timing.jsonl` and emits a one-line distribution summary as
# Stop additionalContext when the session releases. Surfaces via the
# `/ulw-time` skill, `/ulw-status`, and `/ulw-report` cross-session
# rollups. Default `on` because the hook layer is append-only and
# non-blocking; opt out on shared machines or when the residual disk
# noise (one JSONL per session) is unwanted.
OMC_TIME_TRACKING="${OMC_TIME_TRACKING:-on}"
# Cross-session timing rollup retention (days). Per-session timing files
# are swept by OMC_STATE_TTL_DAYS; this independent TTL governs the
# global aggregate at `~/.claude/quality-pack/timing.jsonl`. Default 30
# days — long enough for monthly reflection, short enough that workflow
# data does not accrue indefinitely on shared machines.
OMC_TIME_TRACKING_XS_RETAIN_DAYS="${OMC_TIME_TRACKING_XS_RETAIN_DAYS:-30}"
OMC_TIME_CARD_MIN_SECONDS="${OMC_TIME_CARD_MIN_SECONDS:-5}"
# Blindspot inventory (v1.28.0): per-project enumeration of routes / env vars
# / tests / docs / config flags / UI files / error states / auth paths /
# release steps / scripts so the intent-broadening directive can give the
# model a concrete surface map to reconcile against. Cached at
# ~/.claude/quality-pack/blindspots/<project_key>.json with a 24h TTL by
# default. Default ON because the scanner is fast (< 1s on typical
# projects), runs on-demand, and the cache means most invocations are
# free reads. Opt out for shared machines / regulated codebases / very
# large monorepos where the scan would be slow.
OMC_BLINDSPOT_INVENTORY="${OMC_BLINDSPOT_INVENTORY:-on}"
# Intent-broadening directive (v1.28.0): when ON, the prompt-intent-router
# injects a project-surface reconciliation directive on complex execution
# / continuation prompts so the model widens its scope check beyond the
# literal prompt text. Defends against the language-as-limitation failure
# mode (the prompt names a surface but the work touches several). Default
# ON; lighter than a hard gate — informational, expects the model to
# surface gaps in its opener under a "Project surfaces touched:" line.
OMC_INTENT_BROADENING="${OMC_INTENT_BROADENING:-on}"
# Blindspot inventory cache TTL (seconds). Default 86400 = 24h — long
# enough that subsequent prompts on the same day reuse the cache for
# free, short enough that surfaces added today don't go missing for
# more than a day. Refresh on demand via
# `bash ~/.claude/skills/autowork/scripts/blindspot-inventory.sh scan --force`.
OMC_BLINDSPOT_TTL_SECONDS="${OMC_BLINDSPOT_TTL_SECONDS:-86400}"

_omc_conf_loaded=0

# Parse a single conf file, applying values that pass validation.
# Env vars always take precedence (checked via _omc_env_* guards).
_parse_conf_file() {
  local conf="$1"
  [[ -f "${conf}" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line}" ]] && continue
    [[ "${line}" != *=* ]] && continue

    key="${line%%=*}"
    value="${line#*=}"

    case "${key}" in
      stall_threshold)
        [[ -z "${_omc_env_stall}" && "${value}" =~ ^[1-9][0-9]*$ ]] && OMC_STALL_THRESHOLD="${value}" || true ;;
      excellence_file_count)
        [[ -z "${_omc_env_excellence}" && "${value}" =~ ^[1-9][0-9]*$ ]] && OMC_EXCELLENCE_FILE_COUNT="${value}" || true ;;
      state_ttl_days)
        [[ -z "${_omc_env_ttl}" && "${value}" =~ ^[1-9][0-9]*$ ]] && OMC_STATE_TTL_DAYS="${value}" || true ;;
      dimension_gate_file_count)
        [[ -z "${_omc_env_dimgate}" && "${value}" =~ ^[1-9][0-9]*$ ]] && OMC_DIMENSION_GATE_FILE_COUNT="${value}" || true ;;
      traceability_file_count)
        [[ -z "${_omc_env_traceability}" && "${value}" =~ ^[1-9][0-9]*$ ]] && OMC_TRACEABILITY_FILE_COUNT="${value}" || true ;;
      guard_exhaustion_mode)
        [[ -z "${_omc_env_exhaustion}" && "${value}" =~ ^(release|warn|strict|silent|scorecard|block)$ ]] && OMC_GUARD_EXHAUSTION_MODE="${value}" || true ;;
      verify_confidence_threshold)
        [[ -z "${_omc_env_verify_conf}" && "${value}" =~ ^[0-9]+$ && "${value}" -le 100 ]] && OMC_VERIFY_CONFIDENCE_THRESHOLD="${value}" || true ;;
      gate_level)
        [[ -z "${_omc_env_gate_level}" && "${value}" =~ ^(basic|standard|full)$ ]] && OMC_GATE_LEVEL="${value}" || true ;;
      custom_verify_mcp_tools)
        [[ -z "${_omc_env_verify_mcp}" && -n "${value}" ]] && OMC_CUSTOM_VERIFY_MCP_TOOLS="${value}" || true ;;
      pretool_intent_guard)
        [[ -z "${_omc_env_pretool_intent}" && "${value}" =~ ^(true|false)$ ]] && OMC_PRETOOL_INTENT_GUARD="${value}" || true ;;
      classifier_telemetry)
        [[ -z "${_omc_env_classifier_tel}" && "${value}" =~ ^(on|off)$ ]] && OMC_CLASSIFIER_TELEMETRY="${value}" || true ;;
      discovered_scope)
        [[ -z "${_omc_env_discovered_scope}" && "${value}" =~ ^(on|off)$ ]] && OMC_DISCOVERED_SCOPE="${value}" || true ;;
      council_deep_default)
        [[ -z "${_omc_env_council_deep_default}" && "${value}" =~ ^(on|off)$ ]] && OMC_COUNCIL_DEEP_DEFAULT="${value}" || true ;;
      auto_memory)
        [[ -z "${_omc_env_auto_memory}" && "${value}" =~ ^(on|off)$ ]] && OMC_AUTO_MEMORY="${value}" || true ;;
      metis_on_plan_gate)
        [[ -z "${_omc_env_metis_on_plan_gate}" && "${value}" =~ ^(on|off)$ ]] && OMC_METIS_ON_PLAN_GATE="${value}" || true ;;
      prometheus_suggest)
        [[ -z "${_omc_env_prometheus_suggest}" && "${value}" =~ ^(on|off)$ ]] && OMC_PROMETHEUS_SUGGEST="${value}" || true ;;
      intent_verify_directive)
        [[ -z "${_omc_env_intent_verify_directive}" && "${value}" =~ ^(on|off)$ ]] && OMC_INTENT_VERIFY_DIRECTIVE="${value}" || true ;;
      exemplifying_directive)
        [[ -z "${_omc_env_exemplifying_directive}" && "${value}" =~ ^(on|off)$ ]] && OMC_EXEMPLIFYING_DIRECTIVE="${value}" || true ;;
      exemplifying_scope_gate)
        [[ -z "${_omc_env_exemplifying_scope_gate}" && "${value}" =~ ^(on|off)$ ]] && OMC_EXEMPLIFYING_SCOPE_GATE="${value}" || true ;;
      prompt_text_override)
        [[ -z "${_omc_env_prompt_text_override}" && "${value}" =~ ^(on|off)$ ]] && OMC_PROMPT_TEXT_OVERRIDE="${value}" || true ;;
      mark_deferred_strict)
        [[ -z "${_omc_env_mark_deferred_strict}" && "${value}" =~ ^(on|off)$ ]] && OMC_MARK_DEFERRED_STRICT="${value}" || true ;;
      wave_override_ttl_seconds)
        [[ -z "${_omc_env_wave_override_ttl}" && "${value}" =~ ^[0-9]+$ ]] && OMC_WAVE_OVERRIDE_TTL_SECONDS="${value}" || true ;;
      stop_failure_capture)
        [[ -z "${_omc_env_stop_failure_capture}" && "${value}" =~ ^(on|off)$ ]] && OMC_STOP_FAILURE_CAPTURE="${value}" || true ;;
      prompt_persist)
        [[ -z "${_omc_env_prompt_persist}" && "${value}" =~ ^(on|off)$ ]] && OMC_PROMPT_PERSIST="${value}" || true ;;
      resume_request_ttl_days)
        [[ -z "${_omc_env_resume_request_ttl}" && "${value}" =~ ^[1-9][0-9]*$ ]] && OMC_RESUME_REQUEST_TTL_DAYS="${value}" || true ;;
      resume_watchdog)
        [[ -z "${_omc_env_resume_watchdog}" && "${value}" =~ ^(on|off)$ ]] && OMC_RESUME_WATCHDOG="${value}" || true ;;
      resume_watchdog_cooldown_secs)
        [[ -z "${_omc_env_resume_watchdog_cooldown}" && "${value}" =~ ^[1-9][0-9]*$ ]] && OMC_RESUME_WATCHDOG_COOLDOWN_SECS="${value}" || true ;;
      time_tracking)
        [[ -z "${_omc_env_time_tracking}" && "${value}" =~ ^(on|off)$ ]] && OMC_TIME_TRACKING="${value}" || true ;;
      time_tracking_xs_retain_days)
        [[ -z "${_omc_env_time_tracking_xs_retain}" && "${value}" =~ ^[1-9][0-9]*$ ]] && OMC_TIME_TRACKING_XS_RETAIN_DAYS="${value}" || true ;;
      time_card_min_seconds)
        [[ -z "${_omc_env_time_card_min_seconds}" && "${value}" =~ ^[0-9]+$ ]] && OMC_TIME_CARD_MIN_SECONDS="${value}" || true ;;
      output_style)
        [[ -z "${_omc_env_output_style}" && "${value}" =~ ^(opencode|executive|preserve)$ ]] && OMC_OUTPUT_STYLE="${value}" || true ;;
      model_drift_canary)
        [[ -z "${_omc_env_model_drift_canary}" && "${value}" =~ ^(on|off)$ ]] && OMC_MODEL_DRIFT_CANARY="${value}" || true ;;
      blindspot_inventory)
        [[ -z "${_omc_env_blindspot_inventory}" && "${value}" =~ ^(on|off)$ ]] && OMC_BLINDSPOT_INVENTORY="${value}" || true ;;
      intent_broadening)
        [[ -z "${_omc_env_intent_broadening}" && "${value}" =~ ^(on|off)$ ]] && OMC_INTENT_BROADENING="${value}" || true ;;
      blindspot_ttl_seconds)
        [[ -z "${_omc_env_blindspot_ttl}" && "${value}" =~ ^[1-9][0-9]*$ ]] && OMC_BLINDSPOT_TTL_SECONDS="${value}" || true ;;
      claude_bin)
        # v1.31.0 Wave 1: pinned absolute path to the `claude` binary so
        # the resume-watchdog daemon (LaunchAgent / systemd-user) launches
        # the user's chosen Claude Code install instead of whatever lands
        # first in the daemon's PATH (PATH-hijack defense — security-lens
        # F-5). Validation requires absolute path; relative paths are
        # silently ignored. Empty (default) preserves the legacy live
        # `command -v claude` lookup. Host-specific — do not sync across
        # machines if the binary lives at different paths.
        [[ -z "${_omc_env_claude_bin}" && "${value}" =~ ^/ ]] && OMC_CLAUDE_BIN="${value}" || true ;;
      resume_request_per_cwd_cap)
        # v1.31.0 Wave 1: max resume_request.json artifacts per cwd before
        # stop-failure-handler prunes oldest. Default 3 (sensible for a
        # week of intermittent rate-limits). 0 disables sweep entirely
        # (regulated environments where every artifact must persist).
        [[ -z "${_omc_env_resume_request_per_cwd_cap}" && "${value}" =~ ^[0-9]+$ ]] && OMC_RESUME_REQUEST_PER_CWD_CAP="${value}" || true ;;
    esac
  done < "${conf}"
}

load_conf() {
  if [[ "${_omc_conf_loaded}" -eq 1 ]]; then return; fi
  _omc_conf_loaded=1

  # Layer 1: User-level config
  _parse_conf_file "${HOME}/.claude/oh-my-claude.conf"

  # Layer 2: Project-level config (overrides user-level).
  # Walk up from $PWD looking for .claude/oh-my-claude.conf, capped at 10
  # levels. Skip $HOME to avoid double-reading the user conf.
  local _dir="${PWD}"
  local _depth=0
  while [[ "${_dir}" != "/" && "${_depth}" -lt 10 ]]; do
    if [[ "${_dir}" != "${HOME}" && -f "${_dir}/.claude/oh-my-claude.conf" ]]; then
      _parse_conf_file "${_dir}/.claude/oh-my-claude.conf"
      break
    fi
    _dir="$(dirname "${_dir}")"
    _depth=$((_depth + 1))
  done
}

# Load conf at source time so all scripts get configured values.
load_conf

# Normalize legacy exhaustion mode names to new canonical names.
# Accepts both old (release/warn/strict) and new (silent/scorecard/block).
case "${OMC_GUARD_EXHAUSTION_MODE}" in
  release) OMC_GUARD_EXHAUSTION_MODE="silent" ;;
  warn)    OMC_GUARD_EXHAUSTION_MODE="scorecard" ;;
  strict)  OMC_GUARD_EXHAUSTION_MODE="block" ;;
esac

# Returns 0 (true) when auto-memory is enabled, 1 (false) when explicitly
# disabled via conf. The auto-memory.md and compact.md rules use this to
# decide whether to write memory at session-stop and pre-compact moments.
is_auto_memory_enabled() {
  [[ "${OMC_AUTO_MEMORY:-on}" != "off" ]]
}

# Returns 0 (true) when StopFailure capture is enabled, 1 (false) when
# disabled. The hook records `original_objective` and `last_user_prompt`
# verbatim into resume_request.json, so shared-machine and regulated-
# codebase users may want to suppress it. Default on; mirrors the
# auto_memory and classifier_telemetry opt-out shape.
is_stop_failure_capture_enabled() {
  [[ "${OMC_STOP_FAILURE_CAPTURE:-on}" != "off" ]]
}

# Returns 0 (true) when in-session prompt persistence is enabled (default),
# 1 (false) when disabled via `prompt_persist=off`. When disabled, the
# UserPromptSubmit hook skips the `recent_prompts.jsonl` append and clears
# `last_user_prompt` in session state to an empty string instead of the
# verbatim prompt; the prompt-text-override defense-in-depth path in
# pretool-intent-guard.sh degrades gracefully (empty consumer read => no
# imperative-tail authorization, classifier widening still works); the
# cross-session prompt_preview lift in record_gate_event also short-circuits.
# Default on. Distinct from `auto_memory` (cross-session memory files) and
# `pretool_intent_guard=off` (full guard disable) — this is the granular
# in-session prompt-text horizon.
is_prompt_persist_enabled() {
  [[ "${OMC_PROMPT_PERSIST:-on}" != "off" ]]
}

# Returns 0 (true) when the resume watchdog is opted in, 1 (false)
# otherwise. Default off — the watchdog launches `claude --resume`
# on the user's behalf, which is meaningful behavior change. Enable
# via `resume_watchdog=on` in oh-my-claude.conf or env
# OMC_RESUME_WATCHDOG=on, then run install-resume-watchdog.sh to
# register the platform-specific scheduler.
is_resume_watchdog_enabled() {
  [[ "${OMC_RESUME_WATCHDOG:-off}" == "on" ]]
}

# Returns 0 (true) when time-tracking is enabled, 1 (false) when
# disabled. PreToolUse / PostToolUse / Stop hooks check this for an
# early fast-path exit so opt-out is essentially free of overhead.
# Default on; opt out on shared machines where workflow data should
# not accrue to disk.
is_time_tracking_enabled() {
  [[ "${OMC_TIME_TRACKING:-on}" != "off" ]]
}

# is_model_drift_canary_enabled — v1.26.0 Wave 2.
#
# Default ON. The canary subsystem is a passive, hook-based detector for
# silent confabulation patterns (the model claims verification work it
# did not actually do — "I read X.swift" without a Read call on X.swift
# in the same turn). Surfaces drift signals in `/ulw-report` and as a
# soft in-session alert when the per-session unverified-claim count
# crosses threshold. No new daemon process; runs at Stop time only.
#
# Opt-out by setting `model_drift_canary=off` in oh-my-claude.conf or
# `OMC_MODEL_DRIFT_CANARY=off` in env. Use the opt-out for shared-machine
# privacy or when the audit's prose-parsing overhead is unwelcome on
# very high-volume workflows. Stop hook checks this for early-exit so
# opt-out is essentially free of overhead.
is_model_drift_canary_enabled() {
  [[ "${OMC_MODEL_DRIFT_CANARY:-on}" != "off" ]]
}

# is_blindspot_inventory_enabled — v1.28.0.
# When ON (default), the blindspot-inventory.sh scanner is allowed to
# read/write the cache at ~/.claude/quality-pack/blindspots/<key>.json.
# When OFF, scanner short-circuits with no output and the
# intent-broadening directive does not fire (no inventory to reference).
is_blindspot_inventory_enabled() {
  [[ "${OMC_BLINDSPOT_INVENTORY:-on}" != "off" ]]
}

# is_intent_broadening_enabled — v1.28.0.
# Gate for the intent-broadening directive injection in
# prompt-intent-router.sh. Default ON. Independent of
# blindspot_inventory: a user may want the directive's reasoning
# discipline (reconcile against project context) without the inventory
# scanner running — in which case the directive renders without the
# inventory path reference.
is_intent_broadening_enabled() {
  [[ "${OMC_INTENT_BROADENING:-on}" != "off" ]]
}

# blindspot_inventory_path — v1.28.0.
# Resolves the cache path for the current project. Used by the directive
# injection so the model can read the inventory directly. Returns the
# path on stdout even when the file does not exist (caller checks).
blindspot_inventory_path() {
  local key
  key="$(_omc_project_key 2>/dev/null || true)"
  if [[ -z "${key}" ]]; then
    return 0
  fi
  printf '%s/.claude/quality-pack/blindspots/%s.json' "${HOME}" "${key}"
}

# blindspot_inventory_summary — v1.28.0.
# Emits a one-line summary of the cached inventory's surface counts
# (e.g., "type=bash total=142 routes=0 envs=8 docs=50 cfgs=33").
# Used by the directive to give the model a quick sense of what the
# inventory contains before they decide to read it. Returns empty
# when the cache is missing or malformed.
blindspot_inventory_summary() {
  local path
  path="$(blindspot_inventory_path)"
  [[ -n "${path}" && -f "${path}" ]] || return 0
  jq -r '
    "type=\(.project_type) total=\(.total_surfaces) routes=\(.surfaces.routes | length) envs=\(.surfaces.env_vars | length) docs=\(.surfaces.docs | length) cfgs=\(.surfaces.config_flags | length) ui=\(.surfaces.ui_files | length) errs=\(.surfaces.error_states | length) auths=\(.surfaces.auth_paths | length) releases=\(.surfaces.release_steps | length) scripts=\(.surfaces.scripts | length)"
  ' "${path}" 2>/dev/null || true
}

# find_claimable_resume_requests
#
# Walks STATE_ROOT/*/resume_request.json and emits a JSONL stream on stdout,
# one row per CLAIMABLE artifact, sorted by captured_at_ts descending (newest
# first). Each row is augmented with two synthesized fields the caller will
# need but the on-disk artifact does not store directly:
#
#   .path  — absolute path to the resume_request.json
#   .age_seconds — current_epoch - captured_at_ts (>= 0)
#
# An artifact is "claimable" when ALL of the following hold:
#   1. The parent directory name passes validate_session_id (rejects flat
#      files like hooks.log and any path-traversal shenanigans).
#   2. The JSON parses (.schema_version is present).
#   3. .resumed_at_ts is null/absent (not yet claimed).
#   4. .resume_attempts is 0 or absent (no prior attempt; Wave 3 watchdog
#      will revisit this for retries via a separate code path).
#   5. .captured_at_ts is within OMC_RESUME_REQUEST_TTL_DAYS (default 7d).
#   6. Either .resets_at_ts is null/absent (raw-API session — no rate-limit
#      window data, treated as informational), OR .resets_at_ts <= now
#      (rate cap has cleared).
#
# Caller responsibilities:
#   - Honor is_stop_failure_capture_enabled at the call site (this helper
#     intentionally does not gate on the flag — Wave 1 hook checks before
#     calling, watchdog checks before calling, /ulw-resume skill checks too).
#   - Filter by cwd if needed (rows include .cwd unchanged from artifact).
#
# Returns 0 with empty stdout when nothing matches. Never errors. Bash 3.2-safe.
find_claimable_resume_requests() {
  [[ -d "${STATE_ROOT}" ]] || return 0

  local ttl_days="${OMC_RESUME_REQUEST_TTL_DAYS:-7}"
  local now_ts
  now_ts="$(now_epoch)"
  local cutoff_ts=$(( now_ts - ttl_days * 86400 ))

  shopt -s nullglob
  local dirs=("${STATE_ROOT}"/*/)
  shopt -u nullglob
  if [[ "${#dirs[@]}" -eq 0 ]]; then
    return 0
  fi

  local raw_rows=""
  local d sid artifact
  for d in "${dirs[@]}"; do
    # Reject symlinks. An attacker (shared-machine peer, restored
    # backup, synced .claude/) who can drop entries under STATE_ROOT
    # could otherwise place a UUID-shaped symlink pointing at an
    # attacker-controlled directory containing a hostile
    # resume_request.json. The directory-trailing slash on the glob
    # already follows symlinks, so we have to strip the slash before
    # the [[ -L ]] test — bash's -L returns true for a symlink whose
    # path-form has no trailing slash, even when the target is a dir.
    [[ -L "${d%/}" ]] && continue
    sid="$(basename "${d}")"
    validate_session_id "${sid}" || continue
    artifact="${d%/}/resume_request.json"
    [[ -f "${artifact}" ]] || continue
    # Also reject when the artifact itself is a symlink — pointing it
    # at a victim file (e.g. ~/.ssh/config) wouldn't pass jq -e but
    # leaks read attempts via stat-style side effects elsewhere.
    [[ -L "${artifact}" ]] && continue
    jq -e . "${artifact}" >/dev/null 2>&1 || continue

    local row
    row="$(jq -c \
      --argjson now "${now_ts}" \
      --argjson cutoff "${cutoff_ts}" \
      --arg path "${artifact}" \
      '
      # Coerce numeric fields defensively — older artifacts or test
      # fixtures may have surprising types. tonumber? returns empty
      # on failure rather than throwing, and `// 0` then defaults.
      def as_num: (tonumber? // 0);
      ((.captured_at_ts // 0) | as_num) as $captured_at
      | ((.resets_at_ts // null) | if . == null then null else (as_num) end) as $resets_at
      | ((.resume_attempts // 0) | as_num) as $attempts
      | select(
          (.schema_version // 0) > 0
          and (.resumed_at_ts // null) == null
          and (.dismissed_at_ts // null) == null
          and $attempts == 0
          and $captured_at >= $cutoff
          and (
            $resets_at == null
            or $resets_at <= $now
          )
        )
      | . + {
          path: $path,
          age_seconds: ($now - $captured_at),
          captured_at_ts: $captured_at,
          resets_at_ts: $resets_at,
          resume_attempts: $attempts,
          project_key: (.project_key // null)
        }
      ' "${artifact}" 2>/dev/null || true)"
    [[ -z "${row}" ]] && continue
    raw_rows+="${row}"$'\n'
  done

  [[ -z "${raw_rows}" ]] && return 0

  # Sort by captured_at_ts desc using jq (-s slurp).
  printf '%s' "${raw_rows}" | jq -s -c 'sort_by(-(.captured_at_ts // 0)) | .[]' 2>/dev/null || true
}

# Returns the *conventional* directory where the current cwd's
# user-scope auto-memory would live, following Claude Code's project-
# memory path convention (cwd → cwd with `/` → `-`). Empty stdout when
# cwd is unavailable. Does NOT check `is_auto_memory_enabled` — callers
# that should respect the opt-out must gate themselves before calling.
# Does NOT check whether the directory exists on disk.
omc_memory_dir_for_cwd() {
  local pwd_abs encoded_cwd
  pwd_abs="$(pwd 2>/dev/null || true)"
  [[ -z "${pwd_abs}" ]] && return 0
  encoded_cwd="$(printf '%s' "${pwd_abs}" | tr '/' '-')"
  printf '%s' "${HOME}/.claude/projects/${encoded_cwd}/memory"
}

# Memory drift detector — prints a one-line hint when the user-scope
# auto-memory directory contains files older than 30 days. Stays silent
# (empty stdout) when:
#   - auto_memory=off (no rule to nudge against);
#   - the memory dir does not exist (no rot to flag);
#   - all files are within the 30-day window.
#
# The hint is consumed by prompt-intent-router.sh as a context_parts
# injection at the start of a session and guarded by the
# `memory_drift_hint_emitted` state flag so it fires once per session.
# Used by Wave 3 of the v1.20.0 auto-memory tightening.
check_memory_drift() {
  is_auto_memory_enabled || return 0
  local memory_dir
  memory_dir="$(omc_memory_dir_for_cwd)"
  [[ -z "${memory_dir}" ]] && return 0
  [[ -d "${memory_dir}" ]] || return 0
  local stale_count
  stale_count="$(find "${memory_dir}" -maxdepth 1 -type f -name '*.md' \
    -not -name 'MEMORY.md' -mtime +30 2>/dev/null \
    | wc -l | tr -d '[:space:]')"
  [[ -z "${stale_count}" ]] && stale_count=0
  if (( stale_count > 0 )); then
    printf 'MEMORY DRIFT HINT: %d memory file(s) in this project are older than 30 days. Verify any named files, flags, or claims against the current code before relying on them. Run /memory-audit to triage and consolidate.' \
      "${stale_count}"
  fi
}

# Hook logging — two channels, one file (${HOOK_LOG}).
#
#   log_anomaly  — always on. Use for rare warnings: state corruption,
#                  lock exhaustion, invalid session ids, schema drift.
#                  These are the events worth seeing in a bug report
#                  without asking the user to opt into a debug mode.
#                  Tagged `[anomaly]`.
#
#   log_hook     — debug-gated (hook_debug=true in oh-my-claude.conf
#                  or HOOK_DEBUG=1 env). Use for verbose per-hook
#                  traces ("mark-edit file=x is_doc=0"). Noisy in a
#                  long session, which is why it stays opt-in.
#                  Tagged `[debug]`.
#
# Both channels share the same rotation: truncate to 1500 lines once
# the log exceeds 2000, so the default-on anomaly channel cannot grow
# unbounded even on a machine where something misbehaves every session.
# Grep `[anomaly]` to see only warnings; `[debug]` for verbose traces.
_hook_debug_enabled=""
_hook_debug_checked=0

is_hook_debug() {
  if [[ "${_hook_debug_checked}" -eq 0 ]]; then
    _hook_debug_checked=1
    local conf="${HOME}/.claude/oh-my-claude.conf"
    if [[ "${HOOK_DEBUG:-}" == "1" ]]; then
      _hook_debug_enabled=1
    elif [[ -f "${conf}" ]]; then
      _hook_debug_enabled="$(grep -E '^hook_debug=true$' "${conf}" >/dev/null 2>&1 && echo 1 || echo "")"
    fi
  fi
  [[ -n "${_hook_debug_enabled}" ]]
}

_write_hook_log() {
  local tag="$1"
  local hook_name="${2:-unknown}"
  local detail="${3:-}"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  mkdir -p "${STATE_ROOT}" 2>/dev/null || return 0
  printf '%s  [%s]  %s  %s\n' "${ts}" "${tag}" "${hook_name}" "${detail}" >>"${HOOK_LOG}" 2>/dev/null || return 0

  local _line_count
  _line_count="$(wc -l < "${HOOK_LOG}" 2>/dev/null || echo 0)"
  _line_count="${_line_count##* }"
  if [[ "${_line_count}" -gt 2000 ]]; then
    local _temp
    _temp="$(mktemp "${HOOK_LOG}.XXXXXX" 2>/dev/null)" || return 0
    if tail -n 1500 "${HOOK_LOG}" >"${_temp}" 2>/dev/null; then
      mv "${_temp}" "${HOOK_LOG}" 2>/dev/null || rm -f "${_temp}"
    else
      rm -f "${_temp}"
    fi
  fi
}

log_anomaly() {
  _write_hook_log "anomaly" "$@"
}

log_hook() {
  if is_hook_debug; then
    _write_hook_log "debug" "$@"
  fi
}

# emit_stop_message <body>
#
# Print a Stop-hook output that is RENDERED TO THE USER as a non-blocking
# system message. Stop hooks have a peculiar output schema (see Anthropic
# hooks docs): `hookSpecificOutput.additionalContext` is silently dropped
# at Stop and SubagentStop, so the only path for user-visible text is the
# top-level `systemMessage` field. v1.24.0 / v1.25.0 shipped the bug
# where stop-time-summary used `additionalContext` and the time card
# never rendered; the fix was prose ("don't use additionalContext at
# Stop"). v1.30.0 encodes the contract here so the next Stop-hook author
# cannot accidentally repeat the failure mode — `emit_stop_message` has
# no parameter for additionalContext, so the misuse is impossible.
#
# Use for non-blocking user-visible Stop output: time-breakdown card,
# scorecard release notice, drift-canary alert, etc. For Stop output that
# also blocks the model from stopping, use `emit_stop_block`.
emit_stop_message() {
  local body="$1"
  jq -nc --arg msg "${body}" '{systemMessage: $msg}'
}

# emit_stop_block <reason>
#
# Print a Stop-hook output that BLOCKS the model from stopping AND
# delivers the reason text to the model as the rationale. The schema
# is `{decision: "block", reason: $reason}` — a different surface from
# `systemMessage` (the latter is non-blocking). Stop hooks emit only
# one of the two at a time; they are mutually exclusive.
#
# Mirrors emit_stop_message's purpose: encode the contract once so
# future Stop-hook authors cannot misspell the schema. Replaces the
# 10+ identical inline `jq -nc --arg reason "..." '{"decision":"block",...}'`
# call sites scattered across stop-guard.sh.
emit_stop_block() {
  local reason="$1"
  jq -nc --arg reason "${reason}" '{decision:"block", reason:$reason}'
}

json_get() {
  local query="$1"
  jq -r "${query} // empty" <<<"${HOOK_JSON}"
}

# --- Session ID validation ---
# SESSION_ID comes from Claude Code's hook JSON. Validate it as a safe
# filesystem identifier (alphanumeric, hyphens, underscores, dots, 1-128
# chars) to prevent path traversal via session_file(). Rejects slashes,
# null bytes, the ".." sequence, AND any session_id consisting solely
# of dots (`.`, `..`, `...`, etc.) which would resolve session_file()
# paths back to STATE_ROOT itself or its ancestors — polluting the
# state-root namespace and silently sharing artifacts across all
# sessions. Claude Code uses UUIDs, but we accept shorter IDs for test
# compatibility.
#
# v1.31.0 Wave 3 (security-lens new finding): SESSION_ID="." was the
# concrete edge case — it matched `^[a-zA-Z0-9_.-]{1,128}$` and the
# `*".."*` deny was vacuous, so `session_file('foo.json')` resolved to
# `STATE_ROOT/./foo.json` = `STATE_ROOT/foo.json`. The dots-only deny
# closes that without affecting legitimate IDs that contain dots
# alongside other chars (e.g. `1.0-rc.1`).
validate_session_id() {
  local id="$1"
  # Reject empty, oversized, or chars outside the allowed set.
  [[ "${id}" =~ ^[a-zA-Z0-9_.-]{1,128}$ ]] || return 1
  # Reject ".." anywhere (path-traversal token, even partial sequences
  # like "a..b" — there's no legitimate need for ".." in an ID).
  [[ "${id}" != *".."* ]] || return 1
  # Reject dots-only IDs (`.`, `..`, `...`, ...). A pure dot run resolves
  # to a parent or sibling directory under most path semantics.
  [[ ! "${id}" =~ ^\.+$ ]] || return 1
  return 0
}

# state-io.sh provides ensure_session_dir, session_file, read_state,
# write_state, write_state_batch, append_state, append_limited_state,
# with_state_lock, and with_state_lock_batch. Sourced after
# validate_session_id and log_anomaly are defined (the lib calls
# both) so dependencies are in scope at source time.
#
# Resolve potentially-symlinked common.sh path so the lib loads from
# the real bundle location even when common.sh is symlinked (e.g.
# tests symlink common.sh to a temp HOME; users may symlink to custom
# locations). Portable readlink loop — works with BSD readlink (macOS)
# and GNU readlink (Linux) without depending on `realpath`.
_omc_resolve_path() {
  local p="$1"
  local i=0
  # Cap at 16 hops as a defense-in-depth bound against circular symlinks
  # (e.g. a → b → a). Real-world install layouts never hit this; the bound
  # exists so a malformed symlink can't cause a hook to spin indefinitely.
  while [[ -L "${p}" && "${i}" -lt 16 ]]; do
    local target
    target="$(readlink "${p}")"
    case "${target}" in
      /*) p="${target}" ;;
      *)  p="$(cd "$(dirname "${p}")" && pwd)/${target}" ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' "${p}"
}
_omc_self="$(_omc_resolve_path "${BASH_SOURCE[0]}")"
_omc_self_dir="$(cd "$(dirname "${_omc_self}")" && pwd -P)"
source "${_omc_self_dir}/lib/state-io.sh"
source "${_omc_self_dir}/lib/verification.sh"

# v1.27.0 (F-020 / F-021): lazy-loadable libs.
#
# `_omc_load_timing` and `_omc_load_classifier` source their respective
# libs idempotently — repeat calls are no-ops once the guard variable
# flips. Hooks that genuinely need the lib (timing helpers, classifier
# functions) call the loader explicitly. Hooks that don't (most edit/
# record/state hooks) opt out by setting `OMC_LAZY_<NAME>=1` in their
# environment BEFORE sourcing common.sh — that skips the eager source
# below and the loader is only invoked if a downstream caller asks for
# it. ~5 ms saved per skipped lib × many hook firings per turn.
#
# Internal common.sh functions that depend on classifier
# (`is_advisory_request`, `is_session_management_request`) call
# `_omc_load_classifier` themselves so a hook that opts out of the
# eager source but later calls those functions still gets a working
# classifier — no function-not-found errors. Because the loader is
# idempotent the per-call cost is one bash arithmetic check.
_omc_classifier_loaded=0
_omc_load_classifier() {
  if [[ "${_omc_classifier_loaded}" -eq 1 ]]; then return 0; fi
  # shellcheck disable=SC1091
  source "${_omc_self_dir}/lib/classifier.sh"
  _omc_classifier_loaded=1
}
_omc_timing_loaded=0
_omc_load_timing() {
  if [[ "${_omc_timing_loaded}" -eq 1 ]]; then return 0; fi
  # shellcheck disable=SC1091
  source "${_omc_self_dir}/lib/timing.sh"
  _omc_timing_loaded=1
}

# Eager-load timing.sh by default. Hooks that don't need it set
# OMC_LAZY_TIMING=1 before sourcing common.sh.
if [[ "${OMC_LAZY_TIMING:-0}" != "1" ]]; then
  _omc_load_timing
fi
# classifier.sh is sourced later (after its dependencies — project_profile_has,
# is_advisory_request, etc. — are defined). _omc_self_dir stays in scope until
# the bottom of this file, where every source statement has finished running.
unset -f _omc_resolve_path

now_epoch() {
  date +%s
}

# --- State directory TTL sweep ---
# Deletes session state dirs older than OMC_STATE_TTL_DAYS (default 7).
# Runs at most once per day, gated by a marker file timestamp.

# _cap_cross_session_jsonl <file> <cap> <retain>
# Caps a cross-session JSONL aggregate. No-op when the file is missing or
# at/below cap. On overflow, holds with_cross_session_log_lock, re-reads
# the line count under the lock (concurrent writers may have appended
# between the cheap pre-check and the lock acquisition), then truncates
# to the last <retain> lines via atomic rename. On tail failure, leaves
# the original untouched.
#
# Concurrency (v1.30.0 sre-lens F-2 fix): cap fires under
# with_cross_session_log_lock so concurrent writers from a parallel
# SubagentStop fan-out (council Phase 8 → 30+ gate_events / serendipity
# / archetype rows) cannot land between tail and mv. The cheap pre-check
# avoids paying the lock cost on the steady-state cap-not-needed path
# (every common.sh source touches this for the daily sweep). Writers to
# the underlying JSONL still append unlocked relying on POSIX line
# atomicity (PIPE_BUF-bounded rows); locking the writers too would
# regress hot-path latency for negligible additional safety.
_cap_cross_session_jsonl() {
  local file="$1" cap="$2" retain="$3"
  [[ -f "${file}" ]] || return 0
  local lines
  lines="$(wc -l < "${file}" 2>/dev/null || echo 0)"
  lines="${lines##* }"
  [[ "${lines}" -le "${cap}" ]] && return 0
  with_cross_session_log_lock "${file}" _do_cap_cross_session_jsonl "${file}" "${cap}" "${retain}"
}

# Locked body of _cap_cross_session_jsonl. Re-validates line count
# inside the lock (a peer cap may have already trimmed) before doing
# the trim. The early return when already at/below cap is the fast
# path under contention — multiple peers race to acquire, the first
# trims, the rest see lines<=cap and return without doing the work.
_do_cap_cross_session_jsonl() {
  local file="$1" cap="$2" retain="$3"
  [[ -f "${file}" ]] || return 0
  local lines temp
  lines="$(wc -l < "${file}" 2>/dev/null || echo 0)"
  lines="${lines##* }"
  [[ "${lines}" -le "${cap}" ]] && return 0
  temp="$(mktemp "${file}.XXXXXX")" || return 0
  if tail -n "${retain}" "${file}" > "${temp}" 2>/dev/null; then
    mv "${temp}" "${file}"
  else
    rm -f "${temp}"
  fi
}

# v1.31.0 Wave 2 (sre-lens F-2): locked bodies for cross-session
# aggregation append-paths. Extracted from sweep_stale_sessions so
# with_cross_session_log_lock can wrap the read-pipe-jq-append
# pipeline atomically. Each function reads ONE per-session JSONL,
# tags rows with the source session_id, and appends to the
# cross-session ledger. On error: never abort the sweep, just skip
# this session's contribution.

_sweep_append_misfires() {
  local src_telemetry="$1" sid="$2" dst_misfires="$3"
  grep '"misfire":true' "${src_telemetry}" 2>/dev/null \
    | jq -c --arg sid "${sid}" '. + {session_id: $sid}' 2>/dev/null \
    >> "${dst_misfires}" \
    || true
}

_sweep_append_gate_events() {
  local src_gate_events="$1" sid="$2" dst_gate_events="$3"
  jq -c --arg sid "${sid}" '. + {session_id: $sid}' \
    "${src_gate_events}" 2>/dev/null \
    >> "${dst_gate_events}" \
    || true
}

sweep_stale_sessions() {
  local marker="${STATE_ROOT}/.last_sweep"
  local now
  now="$(date +%s)"

  # Skip if swept within the last 24 hours. v1.30.0 sre-lens F-3 fix:
  # validate the marker is a positive integer before the arithmetic. A
  # corrupt marker (zero-byte file from a crashed prior sweep, garbage
  # chars from a manual mis-edit, partial write from disk-full) would
  # otherwise either crash here under `set -euo pipefail` (empty/non-
  # numeric in `$(( now - last_sweep ))` errors) or evaluate the
  # arithmetic with `last_sweep=0` causing the sweep to re-run on every
  # common.sh source — a CPU storm where every hook invocation walks
  # STATE_ROOT with `find -mtime`. On corrupt input: stamp a fresh
  # epoch and skip THIS round; the next call in 24h proceeds normally.
  if [[ -f "${marker}" ]]; then
    local last_sweep
    last_sweep="$(cat "${marker}" 2>/dev/null || echo "")"
    if [[ ! "${last_sweep}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "${now}" > "${marker}" 2>/dev/null || true
      log_anomaly "sweep_stale_sessions" "non-numeric marker reset to ${now}"
      return
    fi
    if [[ $(( now - last_sweep )) -lt 86400 ]]; then
      return
    fi
  fi

  # Pre-sweep aggregation: capture a summary line per session before deletion.
  # This preserves longitudinal data for quality analysis.
  # No lock needed: sweep is gated by the daily marker file, so only one
  # process runs it at a time. Concurrent writes are structurally impossible.
  local summary_file="${HOME}/.claude/quality-pack/session_summary.jsonl"
  local misfires_file="${HOME}/.claude/quality-pack/classifier_misfires.jsonl"

  if [[ -d "${STATE_ROOT}" ]]; then
    # v1.31.0 Wave 2 (sre-lens F-9): replace `find -mtime +N` with
    # explicit epoch math via a marker file. BSD `find -mtime +N`
    # rounds DOWN (a 7-day-old dir tests false at exactly day 7) and
    # GNU `find -mtime +N` rounds UP — so on Linux a session edited
    # 7d 1m ago is swept, on macOS it is preserved. The boundary
    # divergence is invisible most of the time but produces "where
    # did my resume_request.json go?" surprises. Marker-based math
    # is exact-second-accurate on both platforms.
    local _sweep_cutoff_epoch=$(( now - OMC_STATE_TTL_DAYS * 86400 ))
    local _sweep_cutoff_ts="" _sweep_marker=""
    # BSD `date -r EPOCH` ; GNU `date -d @EPOCH` — try in order.
    _sweep_cutoff_ts="$(date -r "${_sweep_cutoff_epoch}" '+%Y%m%d%H%M.%S' 2>/dev/null \
      || date -d "@${_sweep_cutoff_epoch}" '+%Y%m%d%H%M.%S' 2>/dev/null \
      || printf '')"
    if [[ -n "${_sweep_cutoff_ts}" ]]; then
      _sweep_marker="$(mktemp 2>/dev/null || true)"
      if [[ -n "${_sweep_marker}" ]]; then
        touch -t "${_sweep_cutoff_ts}" "${_sweep_marker}" 2>/dev/null || _sweep_marker=""
      fi
    fi
    local _sweep_find_cmd
    if [[ -n "${_sweep_marker}" ]] && [[ -f "${_sweep_marker}" ]]; then
      # `! -newer marker` = target mtime ≤ marker mtime = older-than-cutoff.
      _sweep_find_cmd="find \"${STATE_ROOT}\" -maxdepth 1 -type d ! -newer \"${_sweep_marker}\" ! -name '.' ! -name '..' ! -name '.*' ! -path \"${STATE_ROOT}\" -print"
    else
      # Fallback when date-format detection fails (exotic libcs, sandboxed env).
      # The legacy -mtime path keeps the BSD/GNU boundary divergence but at
      # least the sweep still functions.
      log_anomaly "sweep_stale_sessions" "marker creation failed; falling back to -mtime"
      _sweep_find_cmd="find \"${STATE_ROOT}\" -maxdepth 1 -type d -mtime +\"${OMC_STATE_TTL_DAYS}\" ! -name '.' ! -name '..' ! -name '.*' ! -path \"${STATE_ROOT}\" -print"
    fi
    eval "${_sweep_find_cmd}" 2>/dev/null | while IFS= read -r _sweep_dir; do
        local _sweep_state="${_sweep_dir}/session_state.json"
        if [[ -f "${_sweep_state}" ]]; then
          local _sweep_sid _sweep_ec=0
          _sweep_sid="$(basename "${_sweep_dir}")"
          local _sweep_edits="${_sweep_dir}/edited_files.log"
          [[ -f "${_sweep_edits}" ]] && _sweep_ec="$(sort -u "${_sweep_edits}" | wc -l | tr -d '[:space:]')"

          # Outcome attribution (added in v1.13.0): joins session-state counters
          # with the per-session findings.json so /ulw-report can answer
          # "did the gates that fired actually lead to fixes?" without
          # walking individual session dirs (already deleted by the sweep).
          local _sweep_findings_file="${_sweep_dir}/findings.json"
          local _sweep_findings_block='null'
          local _sweep_waves_block='null'
          if [[ -f "${_sweep_findings_file}" ]]; then
            _sweep_findings_block="$(jq -c '
              (.findings // []) | {
                total: length,
                shipped:     ([.[] | select(.status=="shipped")]     | length),
                deferred:    ([.[] | select(.status=="deferred")]    | length),
                rejected:    ([.[] | select(.status=="rejected")]    | length),
                in_progress: ([.[] | select(.status=="in_progress")] | length),
                pending:     ([.[] | select(.status=="pending")]     | length)
              }
            ' "${_sweep_findings_file}" 2>/dev/null || echo 'null')"
            _sweep_waves_block="$(jq -c '
              (.waves // []) | {
                total:     length,
                completed: ([.[] | select(.status=="completed")] | length)
              }
            ' "${_sweep_findings_file}" 2>/dev/null || echo 'null')"
          fi
          jq -c --arg sid "${_sweep_sid}" --argjson ec "${_sweep_ec:-0}" \
            --argjson findings "${_sweep_findings_block}" \
            --argjson waves "${_sweep_waves_block}" '
            {
              session_id: $sid,
              start_ts: (.session_start_ts // .last_user_prompt_ts // null),
              end_ts: (.last_edit_ts // .last_review_ts // null),
              domain: (.task_domain // "unknown"),
              intent: (.task_intent // "unknown"),
              edit_count: $ec,
              code_edits: ((.code_edit_count // "0") | tonumber),
              doc_edits: ((.doc_edit_count // "0") | tonumber),
              verified: (if .last_verify_ts then true else false end),
              verify_outcome: (.last_verify_outcome // null),
              verify_confidence: ((.last_verify_confidence // "0") | tonumber),
              reviewed: (if .last_review_ts then true else false end),
              guard_blocks: ((.stop_guard_blocks // "0") | tonumber),
              dim_blocks: ((.dimension_guard_blocks // "0") | tonumber),
              exhausted: (if .guard_exhausted then true else false end),
              dispatches: ((.subagent_dispatch_count // "0") | tonumber),
              outcome: (.session_outcome // "abandoned"),
              skip_count: ((.skip_count // "0") | tonumber),
              serendipity_count: ((.serendipity_count // "0") | tonumber),
              findings: $findings,
              waves: $waves
            }
          ' "${_sweep_state}" >> "${summary_file}" 2>/dev/null || true

          # v1.31.0 Wave 2 (sre-lens F-2): aggregation appends to cross-
          # session JSONL files run UNDER the cross-session log lock. The
          # daily-marker gate makes concurrent SWEEPS structurally
          # impossible, but a parallel watchdog tick / record-* helper
          # writing to the same cross-session JSONL during the sweep
          # CAN race the appender — their unlocked writes interleave
          # with the sweep's piped jq output and tear rows when the
          # combined size crosses PIPE_BUF on Linux. Wrap the appends
          # under with_cross_session_log_lock for symmetry with the
          # _cap_cross_session_jsonl rotation path (also under-lock as
          # of v1.30.0 Wave 3).

          # Classifier telemetry: append this session's misfire rows to the
          # cross-session ledger. Tagged with session id so post-hoc
          # analysis can group by session, intent, reason, etc.
          local _sweep_telemetry="${_sweep_dir}/classifier_telemetry.jsonl"
          if [[ -f "${_sweep_telemetry}" ]]; then
            with_cross_session_log_lock "${misfires_file}" \
              _sweep_append_misfires "${_sweep_telemetry}" "${_sweep_sid}" "${misfires_file}" \
              || _sweep_append_misfires "${_sweep_telemetry}" "${_sweep_sid}" "${misfires_file}"
          fi

          # Gate events: append this session's per-event outcome rows to
          # the cross-session ledger so /ulw-report can answer "did this
          # gate-fire actually catch a real bug?" at the per-event grain.
          # Tagged with session id for grouping.
          local _sweep_gate_events="${_sweep_dir}/gate_events.jsonl"
          local _gate_events_file="${HOME}/.claude/quality-pack/gate_events.jsonl"
          if [[ -f "${_sweep_gate_events}" ]]; then
            with_cross_session_log_lock "${_gate_events_file}" \
              _sweep_append_gate_events "${_sweep_gate_events}" "${_sweep_sid}" "${_gate_events_file}" \
              || _sweep_append_gate_events "${_sweep_gate_events}" "${_sweep_sid}" "${_gate_events_file}"
          fi
        fi
        rm -rf "${_sweep_dir}" 2>/dev/null || true
      done

    # Cross-session JSONL caps. Each session produces 0-few misfire rows;
    # session_summary gets one row per swept session; serendipity-log accrues
    # whenever the Serendipity Rule fires (rare); gate_events accrues at
    # ~10-50 rows per session so the cap is sized higher. Caps are sized
    # to the respective row-rate and an O(years) horizon.
    _cap_cross_session_jsonl "${misfires_file}" 1000 800
    _cap_cross_session_jsonl "${summary_file}" 500 400
    _cap_cross_session_jsonl "${HOME}/.claude/quality-pack/serendipity-log.jsonl" 2000 1500
    _cap_cross_session_jsonl "${HOME}/.claude/quality-pack/gate_events.jsonl" 10000 8000
    _cap_cross_session_jsonl "${HOME}/.claude/quality-pack/used-archetypes.jsonl" 500 400

    # Time-tracking cross-session log: TTL is governed by the dedicated
    # OMC_TIME_TRACKING_XS_RETAIN_DAYS flag (default 30) rather than
    # OMC_STATE_TTL_DAYS — workflow timing data is more sensitive than
    # gate telemetry, and a tighter window matches the privacy default
    # for shared machines. Drop rows older than the retention horizon.
    local _xs_time_log="${HOME}/.claude/quality-pack/timing.jsonl"
    if [[ -f "${_xs_time_log}" ]] && [[ -s "${_xs_time_log}" ]]; then
      local _xs_time_cutoff=$(( now - OMC_TIME_TRACKING_XS_RETAIN_DAYS * 86400 ))
      local _xs_time_tmp
      _xs_time_tmp="$(mktemp "${_xs_time_log}.XXXXXX")"
      if jq -c --argjson cutoff "${_xs_time_cutoff}" \
          'select((.ts // 0) >= $cutoff)' \
          "${_xs_time_log}" > "${_xs_time_tmp}" 2>/dev/null; then
        mv "${_xs_time_tmp}" "${_xs_time_log}"
      else
        rm -f "${_xs_time_tmp}"
      fi
      _cap_cross_session_jsonl "${_xs_time_log}" 10000 8000
    fi
  fi

  # Soft-failure on marker write — a full disk or read-only mount must
  # not crash the sweep hook (would propagate a non-zero exit through
  # every common.sh source). The tradeoff: if the marker write
  # silently fails, the next call sees the OLD marker and the 24h
  # gate still works correctly. The loss-of-write only becomes visible
  # after the next 24h boundary, by which point the underlying disk
  # condition is independently fixable.
  printf '%s\n' "${now}" > "${marker}" 2>/dev/null || true
}

# --- end TTL sweep ---

is_maintenance_prompt() {
  local text="$1"
  [[ "${text}" =~ ^[[:space:]]*/(compact|clear|resume|memory|hooks|config|help|permissions|model|doctor|status)([[:space:]]|$) ]]
}

truncate_chars() {
  local limit="$1"
  local text="$2"

  if [[ "${#text}" -le "${limit}" ]]; then
    printf '%s' "${text}"
    return
  fi

  printf '%s...' "${text:0:limit}"
}

trim_whitespace() {
  local text="$1"

  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"

  printf '%s' "${text}"
}

omc_reason_has_concrete_why() {
  local r="$1"
  local lc trimmed

  lc="$(tr '[:upper:]' '[:lower:]' <<<"${r}")"
  trimmed="$(sed -E 's/^[[:space:][:punct:]]+|[[:space:][:punct:]]+$//g' <<<"${lc}")"

  # Self-explanatory reasons. These are the WHY.
  case "${trimmed}" in
    duplicate|obsolete|superseded|wontfix|invalid|"won't fix"|"not applicable"|n/a|"not a bug")
      return 0
      ;;
  esac

  local why_keywords='\b(requires?|require[ds]?|need(s|ed|ing)?|blocked|blocking|superseded|supersedes|replaced|replaces|pending|awaiting|awaits|wait(s|ing)?|because|due[[:space:]]+to|tracks?[[:space:]]+to|tracked[[:space:]]+(in|at)|see[[:space:]]+(#|f-|s-|wave)|after[[:space:]]+(f-|s-|wave|ticket|issue)|until[[:space:]]+(f-|s-|wave|ticket|issue|the[[:space:]]+(release|migration|launch|cutover))|once[[:space:]]+(f-|s-|wave|the))\b'
  if grep -Eiq "${why_keywords}" <<<"${trimmed}"; then
    return 0
  fi

  # Issue/PR/wave/scope-item reference shape (`#42`, `F-001`, `S-002`,
  # `wave 3`, `PR-12`). These point to a successor or duplicate record.
  if grep -Eiq '(\#[0-9]+|\bf-[0-9]+|\bs-[0-9]+|\bwave[[:space:]]+[0-9]+|\bpr-?[0-9]+)' <<<"${trimmed}"; then
    return 0
  fi

  return 1
}

normalize_task_prompt() {
  local text="$1"
  local changed=1
  local nocasematch_was_set=0

  if shopt -q nocasematch; then
    nocasematch_was_set=1
  fi

  shopt -s nocasematch

  while [[ "${changed}" -eq 1 ]]; do
    changed=0

    if [[ "${text}" =~ ^[[:space:]]*/?(ulw|autowork|ultrawork|sisyphus)[[:space:]]*(.*)$ ]]; then
      text="${BASH_REMATCH[2]}"
      changed=1
      continue
    fi

    if [[ "${text}" =~ ^[[:space:]]*ultrathink[[:space:]]*(.*)$ ]]; then
      text="${BASH_REMATCH[1]}"
      changed=1
    fi
  done

  if [[ "${nocasematch_was_set}" -eq 0 ]]; then
    shopt -u nocasematch
  fi

  printf '%s' "${text}"
}

# Extract the user's task body from a /ulw or /autowork skill-body expansion.
# When the CLI expands a slash command like `/ulw <task>`, the hook sees the full
# skill body starting with "Base directory for this skill: ..." followed by
# "Primary task:" and the user's actual task, then a trailing skill-footer
# instruction. Classifying the full expansion misfires because embedded quoted
# content in the task body can trip SM/advisory regexes. This helper returns
# just the user's task body (between the head marker and the first known
# skill-footer), or exit 1 if the primary-task marker isn't present.
#
# The "Primary task:" marker must be line-anchored (preceded by a newline or at
# the very start of the text). Real skill bodies always put the marker on its
# own line; a mid-sentence mention like "the docs say Primary task: should..."
# would otherwise false-positive and extract the wrong slice of the prompt.
#
# Tail-marker list must cover every known ulw/autowork skill footer. Each
# marker is matched with a leading newline so a user task body that quotes the
# footer phrase mid-sentence does not get truncated prematurely. When the ulw
# or autowork SKILL.md footer text changes, add the new literal here so
# extraction stays aligned with the rendered skill body.
extract_skill_primary_task() {
  local text="$1"
  local head_marker='Primary task:'
  local tail_markers=(
    "Follow the \`/autowork\`"
    "Apply the autowork rules to the task above."
  )

  # Line-anchored marker check: either at the start of text, or after a newline.
  if [[ "${text}" != "${head_marker}"* ]] && [[ "${text}" != *$'\n'"${head_marker}"* ]]; then
    return 1
  fi

  local body="${text#*"${head_marker}"}"
  local tm anchored matched=0
  for tm in "${tail_markers[@]}"; do
    anchored=$'\n'"${tm}"
    if [[ "${body}" == *"${anchored}"* ]]; then
      body="${body%%"${anchored}"*}"
      matched=1
    fi
  done

  # No tail marker matched (v1.29.0 metis F-8 — observability-only). The
  # original concern was footer prose ("Apply the autowork rules to the
  # task above.") leaking into classify_task_intent and tripping the
  # imperative classifier on the literal verb "Apply". But that only
  # happens when a tail marker SHOULD have matched (skill format change)
  # — for genuinely tail-marker-less bodies (degenerate test fixtures,
  # third-party skills with custom footers, future Anthropic skill
  # formats), refusing extraction would break the head-extraction
  # contract that callers rely on. Compromise: emit log_anomaly so a
  # skill-body shape change surfaces in /ulw-report, but still return
  # the body so callers continue to get the post-head content. The
  # anomaly is the "verify the tail_markers list is current" signal.
  if [[ "${matched}" -eq 0 ]]; then
    log_anomaly "extract_skill_primary_task" "no known tail marker found; skill body shape may have changed (continuing with full body)"
  fi

  body="$(trim_whitespace "${body}")"
  [[ -n "${body}" ]] || return 1

  printf '%s' "${body}"
}

is_continuation_request() {
  local text="$1"
  local normalized
  local nocasematch_was_set=0

  normalized="$(normalize_task_prompt "${text}")"
  normalized="$(trim_whitespace "${normalized}")"

  if shopt -q nocasematch; then nocasematch_was_set=1; fi
  shopt -s nocasematch

  local result=1
  if [[ "${normalized}" =~ ^[[:space:]]*((continue|resume)([[:space:]]+(the[[:space:]]+previous[[:space:]]+task|from[[:space:]]+where[[:space:]]+you[[:space:]]+left[[:space:]]+off|where[[:space:]]+you[[:space:]]+left[[:space:]]+off))?|carry[[:space:]]+on|keep[[:space:]]+going|pick[[:space:]]+(it|this)[[:space:]]+back[[:space:]]+up|pick[[:space:]]+up[[:space:]]+where[[:space:]]+you[[:space:]]+left[[:space:]]+off|next|go[[:space:]]+on|proceed|finish[[:space:]]+the[[:space:]]+rest|do[[:space:]]+the[[:space:]]+(remaining[[:space:]]+(work|items|tasks)|rest))([[:space:][:punct:]].*)?$ ]]; then
    result=0
  fi

  if [[ "${nocasematch_was_set}" -eq 0 ]]; then shopt -u nocasematch; fi
  return "${result}"
}

extract_continuation_directive() {
  local text="$1"
  local normalized
  local remainder=""
  local nocasematch_was_set=0

  normalized="$(normalize_task_prompt "${text}")"
  normalized="$(trim_whitespace "${normalized}")"

  if shopt -q nocasematch; then
    nocasematch_was_set=1
  fi

  shopt -s nocasematch

  if [[ "${normalized}" =~ ^(continue|resume)[[:space:]]*(.*)$ ]]; then
    remainder="${BASH_REMATCH[2]}"
    if [[ "${remainder}" =~ ^(the[[:space:]]+previous[[:space:]]+task|from[[:space:]]+where[[:space:]]+you[[:space:]]+left[[:space:]]+off|where[[:space:]]+you[[:space:]]+left[[:space:]]+off)[[:space:]]*(.*)$ ]]; then
      remainder="${BASH_REMATCH[2]}"
    fi
  elif [[ "${normalized}" =~ ^(carry[[:space:]]+on|keep[[:space:]]+going|pick[[:space:]]+(it|this)[[:space:]]+back[[:space:]]+up|pick[[:space:]]+up[[:space:]]+where[[:space:]]+you[[:space:]]+left[[:space:]]+off)[[:space:]]*(.*)$ ]]; then
    remainder="${BASH_REMATCH[3]}"
  elif [[ "${normalized}" =~ ^(next|go[[:space:]]+on|proceed|finish[[:space:]]+the[[:space:]]+rest|do[[:space:]]+the[[:space:]]+(remaining[[:space:]]+(work|items|tasks)|rest))[[:space:]]*(.*)$ ]]; then
    remainder="${BASH_REMATCH[4]}"
  fi

  if [[ "${nocasematch_was_set}" -eq 0 ]]; then
    shopt -u nocasematch
  fi

  remainder="$(trim_whitespace "${remainder}")"
  remainder="${remainder#[,:;.-]}"
  remainder="$(trim_whitespace "${remainder}")"

  printf '%s' "${remainder}"
}

workflow_mode() {
  read_state "workflow_mode"
}

# Return 0 if the prompt text contains a ULW activation trigger.
#
# The boundary class [^[:alnum:]_-] around each keyword prevents false
# positives on compound tokens like "ulwtastic" or "preulwalar". Because
# `-` is in that class, the bare `ulw` keyword cannot match `/ulw-demo`
# on its own — the `-` after `ulw` fails the right-boundary check — so
# `ulw-demo` is listed as its own alternative. Ordering within the
# alternation is not load-bearing for correctness.
is_ulw_trigger() {
  local prompt="$1"
  grep -Eiq '(^|[^[:alnum:]_-])(ulw-demo|ultrawork|ulw|autowork|sisyphus)([^[:alnum:]_-]|$)' <<<"${prompt}"
}

is_ultrawork_mode() {
  [[ "$(workflow_mode)" == "ultrawork" ]]
}

task_domain() {
  read_state "task_domain"
}

is_internal_claude_path() {
  local path="$1"

  [[ -z "${path}" ]] && return 1

  case "${path}" in
    "${HOME}/.claude/projects/"*|\
    "${HOME}/.claude/quality-pack/state/"*|\
    "${HOME}/.claude/tasks/"*|\
    "${HOME}/.claude/todos/"*|\
    "${HOME}/.claude/transcripts/"*|\
    "${HOME}/.claude/debug/"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# --- Doc vs code edit classification ---
#
# is_doc_path returns 0 if the given path is a documentation artifact
# (markdown, CHANGELOG, README, anything under a docs/ path component).
# The dimension gate routes doc-only edits to editor-critic rather than
# quality-reviewer, preventing CHANGELOG tweaks from re-opening the
# full code-review loop.
#
# Rules:
#   - Extensions match case-insensitively: md, mdx, txt, rst, adoc, markdown
#   - Basename patterns match well-known doc files (lowercased):
#     changelog*, release*, readme*, authors*, contributing*,
#     license*, notice*, copying*
#   - Path component docs/ or doc/ (not substring: src/docs-examples/foo.ts
#     is NOT a doc; /project/docs/foo.ts IS)

is_doc_path() {
  local path="$1"
  [[ -z "${path}" ]] && return 1

  # Lowercase basename for case-insensitive matching
  local base="${path##*/}"
  local base_lc
  base_lc="$(printf '%s' "${base}" | tr '[:upper:]' '[:lower:]')"

  case "${base_lc}" in
    *.md|*.mdx|*.txt|*.rst|*.adoc|*.markdown) return 0 ;;
    changelog*|release*|readme*|authors*|contributing*|license*|notice*|copying*) return 0 ;;
  esac

  # Path-component docs/ or doc/ — require slash boundary, not substring
  case "/${path}/" in
    */docs/*|*/doc/*) return 0 ;;
  esac

  return 1
}

# is_ui_path — returns 0 for files that produce visible UI output.
#   - Component files: tsx, jsx, vue, svelte, astro
#   - Stylesheets: css, scss, sass, less, styl
#   - Markup: html, htm
# UI paths are a subset of code paths (not docs). A file can be both
# "code" (for code_edit_count) and "ui" (for ui_edit_count).

is_ui_path() {
  local path="$1"
  [[ -z "${path}" ]] && return 1

  local base="${path##*/}"
  local base_lc
  base_lc="$(printf '%s' "${base}" | tr '[:upper:]' '[:lower:]')"

  case "${base_lc}" in
    *.tsx|*.jsx|*.vue|*.svelte|*.astro) return 0 ;;
    *.css|*.scss|*.sass|*.less|*.styl) return 0 ;;
    *.html|*.htm) return 0 ;;
  esac

  return 1
}

# --- Dimension tracking helpers ---
#
# Dimensions are stored as individual state keys of the form
# `dim_<name>_ts` holding the epoch at which the reviewer ticked them.
# Validity is determined by comparing that epoch to the relevant edit
# clock (last_code_edit_ts for code dims, last_doc_edit_ts for prose).
# This gives implicit invalidation — no mark-edit clearing needed.
#
# The canonical dimension set:
#   bug_hunt       — quality-reviewer (code correctness, regressions, edge cases)
#   code_quality   — quality-reviewer (conventions, dead code, comments)
#   stress_test    — metis (hidden assumptions, unsafe paths)
#   prose          — editor-critic (doc clarity, accuracy, tone)
#   completeness   — excellence-reviewer (fresh-eyes holistic review)
#   traceability   — briefing-analyst (deferrals, decisions, synthesis)
#   design_quality — design-reviewer (visual craft, distinctiveness, anti-generic)

_dim_key() {
  printf 'dim_%s_ts' "$1"
}

tick_dimension() {
  # Records a dimension tick under the state lock to prevent lost updates
  # when multiple reviewer SubagentStop hooks fire concurrently.
  local dim="$1"
  local ts="${2:-$(now_epoch)}"
  local key
  key="$(_dim_key "${dim}")"
  with_state_lock write_state "${key}" "${ts}"
}

tick_dimensions_with_verdict() {
  local verdict="$1"
  local ts="${2:-$(now_epoch)}"
  shift 2

  [[ "$#" -gt 0 ]] || return 0

  local args=()
  local dim
  for dim in "$@"; do
    args+=("$(_dim_key "${dim}")" "${ts}" "dim_${dim}_verdict" "${verdict}")
  done

  with_state_lock_batch "${args[@]}"
}

set_dimension_verdicts() {
  local verdict="$1"
  shift

  [[ "$#" -gt 0 ]] || return 0

  local args=()
  local dim
  for dim in "$@"; do
    args+=("dim_${dim}_verdict" "${verdict}")
  done

  with_state_lock_batch "${args[@]}"
}

is_dimension_valid() {
  # Returns 0 if the dimension was ticked at or after the most recent
  # edit of the relevant type. For 'prose', compare to last_doc_edit_ts;
  # all other dimensions compare to last_code_edit_ts (then last_edit_ts
  # as a legacy fallback for resumed sessions).
  #
  # Uses >= (not >) so same-second tick-after-edit sequences count as
  # valid. The production semantics are: "reviewer that ran at time T
  # saw the edit at time T", which is the natural interpretation. In
  # tests, this lets single-second sequences work without sleep calls.
  # Post-tick edits in strict ordering (edit clearly after tick) still
  # invalidate because the edit clock advances at least one second.
  local dim="$1"
  local tick_ts
  tick_ts="$(read_state "$(_dim_key "${dim}")")"
  [[ -z "${tick_ts}" ]] && return 1

  local relevant_edit_ts
  if [[ "${dim}" == "prose" ]]; then
    relevant_edit_ts="$(read_state "last_doc_edit_ts")"
  else
    relevant_edit_ts="$(read_state "last_code_edit_ts")"
    [[ -z "${relevant_edit_ts}" ]] && relevant_edit_ts="$(read_state "last_edit_ts")"
  fi

  # No relevant edit recorded: tick is valid by default.
  [[ -z "${relevant_edit_ts}" ]] && return 0

  [[ "${tick_ts}" -ge "${relevant_edit_ts}" ]]
}

reviewer_for_dimension() {
  case "$1" in
    bug_hunt|code_quality) printf 'quality-reviewer' ;;
    stress_test)           printf 'metis' ;;
    prose)                 printf 'editor-critic' ;;
    completeness)          printf 'excellence-reviewer' ;;
    traceability)          printf 'briefing-analyst' ;;
    design_quality)        printf 'design-reviewer' ;;
    *)                     printf 'quality-reviewer' ;;
  esac
}

describe_dimension() {
  case "$1" in
    bug_hunt)        printf 'bug hunt (correctness, regressions, edge cases)' ;;
    code_quality)    printf 'code quality (conventions, dead code, comments)' ;;
    stress_test)     printf 'stress-test (hidden assumptions, unsafe paths)' ;;
    prose)           printf 'prose review (doc clarity, accuracy, tone)' ;;
    completeness)    printf 'completeness (fresh-eyes holistic review)' ;;
    traceability)    printf 'traceability (deferrals, decisions, synthesis)' ;;
    design_quality)  printf 'design quality (visual craft, distinctiveness, anti-generic)' ;;
    *)               printf '%s' "$1" ;;
  esac
}

# Computes the set of required dimensions for the current session based
# on the edit counters (maintained by mark-edit.sh at write time — no
# O(N) re-classification at stop time). Echoes a csv. Empty string
# means no dimension requirement (legacy path for simple tasks).
#
# Thresholds:
#   unique_count < OMC_DIMENSION_GATE_FILE_COUNT → empty (simple task)
#   Otherwise:                                   → bug_hunt,code_quality,stress_test,completeness
#   If doc_count > 0 or task_domain=writing:     → append prose
#   If ui_count > 0:                             → append design_quality
#   If unique_count >= OMC_TRACEABILITY_FILE_COUNT → append traceability

get_required_dimensions() {
  local code_count doc_count ui_count unique_count
  code_count="$(read_state "code_edit_count")"
  doc_count="$(read_state "doc_edit_count")"
  ui_count="$(read_state "ui_edit_count")"
  code_count="${code_count:-0}"
  doc_count="${doc_count:-0}"
  ui_count="${ui_count:-0}"
  unique_count=$((code_count + doc_count))

  # Legacy fallback: if the counters are not populated (resumed session
  # from pre-dimension-gate state), derive counts AND classification
  # from edited_files.log by scanning each unique path. Without this
  # classification, a resumed doc-only session would route to the code
  # dimension set.
  if [[ "${unique_count}" -eq 0 ]]; then
    local edited_log
    edited_log="$(session_file "edited_files.log")"
    if [[ -f "${edited_log}" ]]; then
      local _path
      while IFS= read -r _path; do
        [[ -z "${_path}" ]] && continue
        unique_count=$((unique_count + 1))
        if is_doc_path "${_path}"; then
          doc_count=$((doc_count + 1))
        else
          code_count=$((code_count + 1))
          if is_ui_path "${_path}"; then
            ui_count=$((ui_count + 1))
          fi
        fi
      done < <(sort -u "${edited_log}")
    fi
  fi

  if [[ "${unique_count}" -lt "${OMC_DIMENSION_GATE_FILE_COUNT}" ]]; then
    printf ''
    return
  fi

  local dims=""
  if [[ "${code_count}" -gt 0 ]] || [[ "${unique_count}" -gt 0 && "${doc_count}" -eq 0 ]]; then
    dims="bug_hunt,code_quality,stress_test,completeness"
  fi

  local td
  td="$(task_domain)"
  if [[ "${doc_count}" -gt 0 ]] || [[ "${td}" == "writing" ]]; then
    if [[ -n "${dims}" ]]; then
      dims="${dims},prose"
    else
      dims="prose,completeness"
    fi
  fi

  # design_quality: appended when UI files (tsx, jsx, vue, css, etc.) were
  # edited. Since UI is a subset of code (both counters increment), dims
  # will always be non-empty when ui_count > 0.
  if [[ "${ui_count}" -gt 0 && -n "${dims}" ]]; then
    dims="${dims},design_quality"
  fi

  if [[ "${unique_count}" -ge "${OMC_TRACEABILITY_FILE_COUNT}" ]]; then
    if [[ -n "${dims}" ]]; then
      dims="${dims},traceability"
    else
      dims="traceability"
    fi
  fi

  printf '%s' "${dims}"
}

# Echoes a csv of dimensions that are NOT currently valid (missing or
# invalidated by post-tick edits). Empty string means all required
# dimensions are satisfied.
missing_dimensions() {
  local required="$1"
  local missing=""
  local tok
  for tok in ${required//,/ }; do
    [[ -z "${tok}" ]] && continue
    if ! is_dimension_valid "${tok}"; then
      if [[ -n "${missing}" ]]; then
        missing="${missing},${tok}"
      else
        missing="${tok}"
      fi
    fi
  done
  printf '%s' "${missing}"
}

# order_dimensions_by_risk: Reorder a comma-separated list of dimensions
# so higher-risk dimensions come first. Returns reordered csv on stdout.
# Priority ordering:
#   1. stress_test (security/edge-case bugs are highest risk)
#   2. bug_hunt (logic bugs)
#   3. code_quality (code health)
#   4. design_quality (UI correctness)
#   5. prose (documentation)
#   6. completeness (holistic review)
#   7. traceability (cross-cutting, lowest risk)
# Within each priority level, the order is stable.
order_dimensions_by_risk() {
  local dims="$1"
  local project_profile="${2:-}"
  local ordered=""

  # Define priority tiers. If project has UI, promote design_quality.
  local priority_order="stress_test,bug_hunt,code_quality"
  if [[ -n "${project_profile}" ]] && project_profile_has "ui" "${project_profile}"; then
    priority_order="${priority_order},design_quality"
  fi
  priority_order="${priority_order},prose,completeness"
  if [[ -n "${project_profile}" ]] && ! project_profile_has "ui" "${project_profile}"; then
    priority_order="${priority_order},design_quality"
  fi
  priority_order="${priority_order},traceability"

  # Select only dims that are in the input list, preserving priority order
  local d
  for d in ${priority_order//,/ }; do
    if [[ ",${dims}," == *",${d},"* ]]; then
      ordered="${ordered:+${ordered},}${d}"
    fi
  done

  # Append any dims not in our priority list (future-proof)
  for d in ${dims//,/ }; do
    if [[ ",${ordered}," != *",${d},"* ]]; then
      ordered="${ordered:+${ordered},}${d}"
    fi
  done

  printf '%s' "${ordered}"
}

# check_clean_sweep: Check if ALL previously-ticked dimensions had CLEAN
# verdicts. Returns 0 (true) if all were clean, 1 otherwise.
# Used for fast-path: if all completed dims were clean, remaining low-risk
# dims can be deferred (logged as skipped in the scorecard).
check_clean_sweep() {
  local required_dims="$1"
  local _dim _verdict _tick_ts
  local any_ticked=0
  local any_findings=0

  for _dim in ${required_dims//,/ }; do
    _tick_ts="$(read_state "$(_dim_key "${_dim}")")"
    if [[ -n "${_tick_ts}" ]]; then
      any_ticked=1
      _verdict="$(read_state "dim_${_dim}_verdict")"
      if [[ "${_verdict}" == "FINDINGS" ]]; then
        any_findings=1
        break
      fi
    fi
  done

  # Clean sweep requires at least one dimension ticked and no findings
  [[ "${any_ticked}" -eq 1 && "${any_findings}" -eq 0 ]]
}

# --- end dimension helpers ---

# --- Verification confidence helpers ---

# detect_project_test_command: Inspect project files to discover the canonical
# test command. Returns the command string on stdout or empty if not detected.
# Looks at package.json, Makefile, Cargo.toml, pyproject.toml, etc.
detect_project_test_command() {
  local project_dir="${1:-.}"
  local test_cmd=""

  # package.json → npm/pnpm/yarn test
  if [[ -f "${project_dir}/package.json" ]]; then
    local scripts_test
    scripts_test="$(jq -r '.scripts.test // empty' "${project_dir}/package.json" 2>/dev/null || true)"
    if [[ -n "${scripts_test}" && "${scripts_test}" != "echo \"Error: no test specified\" && exit 1" ]]; then
      # Detect package manager
      if [[ -f "${project_dir}/pnpm-lock.yaml" ]]; then
        test_cmd="pnpm test"
      elif [[ -f "${project_dir}/yarn.lock" ]]; then
        test_cmd="yarn test"
      elif [[ -f "${project_dir}/bun.lockb" ]]; then
        test_cmd="bun test"
      else
        test_cmd="npm test"
      fi
    fi
  fi

  # Cargo.toml → cargo test
  if [[ -z "${test_cmd}" && -f "${project_dir}/Cargo.toml" ]]; then
    test_cmd="cargo test"
  fi

  # go.mod → go test ./...
  if [[ -z "${test_cmd}" && -f "${project_dir}/go.mod" ]]; then
    test_cmd="go test ./..."
  fi

  # pyproject.toml or setup.py → pytest
  if [[ -z "${test_cmd}" ]]; then
    if [[ -f "${project_dir}/pyproject.toml" ]] || [[ -f "${project_dir}/setup.py" ]]; then
      if [[ -f "${project_dir}/pyproject.toml" ]] \
        && grep -q 'pytest' "${project_dir}/pyproject.toml" 2>/dev/null; then
        test_cmd="pytest"
      elif command -v pytest &>/dev/null || [[ -f "${project_dir}/pytest.ini" ]] \
        || [[ -f "${project_dir}/setup.cfg" ]]; then
        test_cmd="pytest"
      fi
    fi
  fi

  # Makefile with test target
  if [[ -z "${test_cmd}" && -f "${project_dir}/Makefile" ]]; then
    if grep -qE '^test[[:space:]]*:' "${project_dir}/Makefile" 2>/dev/null; then
      test_cmd="make test"
    fi
  fi

  # mix.exs → mix test
  if [[ -z "${test_cmd}" && -f "${project_dir}/mix.exs" ]]; then
    test_cmd="mix test"
  fi

  # Gemfile → bundle exec rspec or rake test
  if [[ -z "${test_cmd}" && -f "${project_dir}/Gemfile" ]]; then
    if [[ -d "${project_dir}/spec" ]]; then
      test_cmd="bundle exec rspec"
    else
      test_cmd="rake test"
    fi
  fi

  # justfile with test recipe → just test
  if [[ -z "${test_cmd}" ]]; then
    local _justfile=""
    for _cand in justfile Justfile .justfile; do
      if [[ -f "${project_dir}/${_cand}" ]]; then
        _justfile="${project_dir}/${_cand}"
        break
      fi
    done
    if [[ -n "${_justfile}" ]] && grep -qE '^test[[:space:]]*:' "${_justfile}" 2>/dev/null; then
      test_cmd="just test"
    fi
  fi

  # Taskfile.yml with test task → task test. We match the Go-Task v3
  # canonical layout — `tasks:` at column 0 followed by an indented
  # `test:` key — instead of loose "any test: line" because a Taskfile
  # can reference `test:` inside `vars:`, `env:`, `requires:`, `deps:`,
  # etc. A loose match would return `task test` for projects whose
  # actual test task has a different name, producing confusing
  # "task: task 'test' not found" errors during stop-guard UX.
  if [[ -z "${test_cmd}" ]]; then
    local _taskfile=""
    for _cand in Taskfile.yml Taskfile.yaml taskfile.yml taskfile.yaml; do
      if [[ -f "${project_dir}/${_cand}" ]]; then
        _taskfile="${project_dir}/${_cand}"
        break
      fi
    done
    if [[ -n "${_taskfile}" ]]; then
      # awk walks the file once: enter the `tasks:` block on a
      # zero-indent `tasks:` line, leave it when a new zero-indent key
      # appears, and inside the block accept an indented `test:` key
      # whose indentation is strictly greater than `tasks:`. Exits 0
      # on find, 1 otherwise.
      if awk '
        /^tasks:[[:space:]]*$/ { in_tasks = 1; next }
        /^[^[:space:]]/ { in_tasks = 0 }
        in_tasks && /^[[:space:]]+test[[:space:]]*:/ { found = 1; exit }
        END { exit found ? 0 : 1 }
      ' "${_taskfile}" 2>/dev/null; then
        test_cmd="task test"
      fi
    fi
  fi

  # Pure-bash projects: look for test orchestrators or a tests/ directory
  # that contains shell test scripts. This tier catches harness-style repos
  # (oh-my-claude itself, dotfiles projects, other pure-shell tooling) where
  # no language manifest exists but a conventional test layout does.
  #
  # Detection precedence:
  #   1. Explicit orchestrator in repo root or scripts/:
  #        run-tests.sh, run_tests.sh, test.sh, tests.sh, run-all.sh
  #   2. Explicit orchestrator inside tests/:
  #        run.sh, runner.sh, run-all.sh, all.sh
  #   3. Alphabetically-first tests/test-*.sh / tests/test_*.sh / tests/*_test.sh
  #      as a concrete starting point. Users running a different test file
  #      from the same directory still score above threshold via the
  #      framework-keyword rule in verification_has_framework_keyword (which
  #      recognizes `bash tests/...sh` as a test framework signal).
  #
  # We never emit `bash tests/test-*.sh` with a literal glob — the shell
  # wouldn't run all files, only the first arg. Emitting a concrete file
  # keeps the advice copy-pasteable.
  if [[ -z "${test_cmd}" ]]; then
    local _orchestrator=""
    for _cand in \
        "${project_dir}/run-tests.sh" \
        "${project_dir}/run_tests.sh" \
        "${project_dir}/test.sh" \
        "${project_dir}/tests.sh" \
        "${project_dir}/run-all.sh" \
        "${project_dir}/scripts/test.sh" \
        "${project_dir}/scripts/run-tests.sh" \
        "${project_dir}/scripts/run_tests.sh" \
        "${project_dir}/tests/run.sh" \
        "${project_dir}/tests/runner.sh" \
        "${project_dir}/tests/run-all.sh" \
        "${project_dir}/tests/run_all.sh" \
        "${project_dir}/tests/all.sh"; do
      if [[ -f "${_cand}" ]]; then
        _orchestrator="${_cand#"${project_dir}/"}"
        break
      fi
    done
    if [[ -n "${_orchestrator}" ]]; then
      test_cmd="bash ${_orchestrator}"
    fi
  fi

  if [[ -z "${test_cmd}" && -d "${project_dir}/tests" ]]; then
    # Alphabetically-first shell test file under tests/. Sort in C locale
    # so the selection is deterministic across environments (same failure
    # mode as the install manifest comparator — sort key differs under
    # different LC_COLLATE).
    local _first_test
    _first_test="$(
      LC_ALL=C find "${project_dir}/tests" -maxdepth 1 -type f \
        \( -name 'test-*.sh' -o -name 'test_*.sh' -o -name '*_test.sh' \) \
        2>/dev/null | LC_ALL=C sort | head -n 1 || true
    )"
    if [[ -n "${_first_test}" ]]; then
      test_cmd="bash ${_first_test#"${project_dir}/"}"
    fi
  fi

  printf '%s' "${test_cmd}"
}

# Verification subsystem (Bash + MCP) extracted to lib/verification.sh in
# v1.14.0. Sourced near the top of common.sh, after lib/state-io.sh.

# --- Stall detection helpers ---

# compute_stall_threshold: Scale the stall threshold based on task complexity.
# A simple 1-file edit should stall at the default (12 reads), while a large
# multi-file task gets more leeway (up to 2x the base threshold).
# Returns integer threshold on stdout.
compute_stall_threshold() {
  local base_threshold="${OMC_STALL_THRESHOLD}"
  local edited_count="${1:-0}"
  local has_plan="${2:-false}"

  # Plans legitimately require more exploration
  local plan_bonus=0
  if [[ "${has_plan}" == "true" ]]; then
    plan_bonus=4
  fi

  # Scale by complexity: 1-2 files=base, 3-5=+4, 6+=+8
  local complexity_bonus=0
  if [[ "${edited_count}" -ge 6 ]]; then
    complexity_bonus=8
  elif [[ "${edited_count}" -ge 3 ]]; then
    complexity_bonus=4
  fi

  printf '%s' "$(( base_threshold + plan_bonus + complexity_bonus ))"
}

# compute_progress_score: Compute a 0-100 progress score for the current session.
# Considers edits made, verifications run, reviews completed, and dimensions ticked.
# Higher scores mean more progress — used to soften stall messages when real work
# is being done alongside exploration.
compute_progress_score() {
  local score=0

  local last_edit_ts last_verify_ts last_review_ts
  last_edit_ts="$(read_state "last_edit_ts")"
  last_verify_ts="$(read_state "last_verify_ts")"
  last_review_ts="$(read_state "last_review_ts")"

  # Edit count from log
  local edited_count=0
  local edited_log
  edited_log="$(session_file "edited_files.log")"
  if [[ -f "${edited_log}" ]]; then
    edited_count="$(sort -u "${edited_log}" | wc -l | tr -d '[:space:]')"
  fi
  edited_count="${edited_count:-0}"

  # Points for edits (up to 30)
  if [[ "${edited_count}" -ge 5 ]]; then
    score=$((score + 30))
  elif [[ "${edited_count}" -ge 1 ]]; then
    score=$((score + edited_count * 6))
  fi

  # Points for verification (up to 20)
  if [[ -n "${last_verify_ts}" ]]; then
    score=$((score + 20))
  fi

  # Points for review (up to 20)
  if [[ -n "${last_review_ts}" ]]; then
    score=$((score + 20))
  fi

  # Points for plan (10)
  local has_plan
  has_plan="$(read_state "has_plan")"
  if [[ "${has_plan}" == "true" ]]; then
    score=$((score + 10))
  fi

  # Points for dimension ticks (up to 20)
  local dim_ticks=0
  local _dim
  for _dim in bug_hunt code_quality stress_test completeness prose traceability design_quality; do
    local _ts
    _ts="$(read_state "$(_dim_key "${_dim}")")"
    if [[ -n "${_ts}" ]]; then
      dim_ticks=$((dim_ticks + 1))
    fi
  done
  if [[ "${dim_ticks}" -ge 4 ]]; then
    score=$((score + 20))
  elif [[ "${dim_ticks}" -ge 1 ]]; then
    score=$((score + dim_ticks * 5))
  fi

  # Cap at 100
  if [[ "${score}" -gt 100 ]]; then
    score=100
  fi

  printf '%s' "${score}"
}

# --- end stall detection helpers ---

# --- Gate recovery line ---
#
# format_gate_recovery_line: emit a standardized "→ Next: <action>"
# recovery hint that gate-block messages append to their reason strings.
# Keeps the Unicode arrow + label shape consistent across all gates so
# users see one canonical "what to do next" cue regardless of which
# gate fired. Empty input returns nothing (no-op safe).
#
# Why standardize: gate-block messages historically buried the unblock
# action inside long prose. Some gates already had implicit next-step
# language ("Next step: run X" in review-coverage; "Still missing: ...
# Next: Y" in the quality gate); others left the user to infer the path
# forward from prose alone (advisory, session-handoff, discovered-scope,
# excellence). The helper lets every gate close with the same line
# shape, so a user skimming a block message can find the recovery in
# one place every time.
#
# Usage:
#   recovery="$(format_gate_recovery_line "read the affected code, then re-summarize")"
#   jq -nc --arg reason "${prose}${recovery}" ...
#
# The literal `→` (U+2192) is embedded directly — jq --arg is binary
# safe and the rendered output uses the exact glyph.
format_gate_recovery_line() {
  local action="${1:-}"
  [[ -z "${action}" ]] && return 0
  printf '\n→ Next: %s' "${action}"
}

# --- end gate recovery line ---

# --- Quality scorecard ---

# build_quality_scorecard: Build a human-readable quality scorecard summarizing
# the current quality gate status. Returns a multi-line string on stdout.
# Used when guards exhaust to give visibility into what was completed vs skipped.
build_quality_scorecard() {
  local sc=""
  local check_mark="✓"
  local cross_mark="✗"
  local dash_mark="–"

  # Verification status
  local last_verify_ts last_verify_outcome last_verify_cmd verify_confidence
  last_verify_ts="$(read_state "last_verify_ts")"
  last_verify_outcome="$(read_state "last_verify_outcome")"
  last_verify_cmd="$(read_state "last_verify_cmd")"
  verify_confidence="$(read_state "last_verify_confidence")"

  if [[ -n "${last_verify_ts}" ]]; then
    if [[ "${last_verify_outcome}" == "passed" ]]; then
      sc="${sc}${check_mark} Verification: passed"
      if [[ -n "${last_verify_cmd}" ]]; then
        sc="${sc} (${last_verify_cmd})"
      fi
      if [[ -n "${verify_confidence}" && "${verify_confidence}" -lt 50 ]]; then
        sc="${sc} [low confidence: ${verify_confidence}%]"
      fi
    else
      sc="${sc}${cross_mark} Verification: FAILED"
      [[ -n "${last_verify_cmd}" ]] && sc="${sc} (${last_verify_cmd})"
    fi
  else
    sc="${sc}${cross_mark} Verification: not run"
  fi
  sc="${sc}\n"

  # Review status
  local last_review_ts review_had_findings
  last_review_ts="$(read_state "last_review_ts")"
  review_had_findings="$(read_state "review_had_findings")"

  if [[ -n "${last_review_ts}" ]]; then
    if [[ "${review_had_findings}" == "true" ]]; then
      sc="${sc}${cross_mark} Code review: findings reported"
    else
      sc="${sc}${check_mark} Code review: clean"
    fi
  else
    sc="${sc}${cross_mark} Code review: not run"
  fi
  sc="${sc}\n"

  # Dimension status
  local required_dims
  required_dims="$(get_required_dimensions 2>/dev/null || true)"
  if [[ -n "${required_dims}" ]]; then
    local _dim _dim_ts _dim_label _dim_verdict
    for _dim in ${required_dims//,/ }; do
      _dim_ts="$(read_state "$(_dim_key "${_dim}")")"
      _dim_verdict="$(read_state "dim_${_dim}_verdict")"
      _dim_label="$(describe_dimension "${_dim}" 2>/dev/null || printf '%s' "${_dim}")"
      if is_dimension_valid "${_dim}"; then
        sc="${sc}${check_mark} ${_dim_label}\n"
      elif [[ "${_dim_verdict}" == "FINDINGS" ]]; then
        sc="${sc}${cross_mark} ${_dim_label}: findings reported\n"
      elif [[ -n "${_dim_ts}" ]]; then
        sc="${sc}${cross_mark} ${_dim_label}: stale after subsequent edits\n"
      else
        sc="${sc}${dash_mark} ${_dim_label}: skipped\n"
      fi
    done
  fi

  # Excellence review
  local last_excellence_ts
  last_excellence_ts="$(read_state "last_excellence_review_ts")"
  if [[ -n "${last_excellence_ts}" ]]; then
    sc="${sc}${check_mark} Excellence review: done\n"
  fi

  printf '%b' "${sc}"
}

# --- end quality scorecard ---

# --- Agent performance metrics (cross-session) ---
# Stored in ~/.claude/quality-pack/agent-metrics.json
# Structure: { "agent_name": { "invocations": N, "clean_verdicts": N,
#   "finding_verdicts": N, "last_used_ts": N, "avg_confidence": N } }

_AGENT_METRICS_FILE="${_AGENT_METRICS_FILE:-${HOME}/.claude/quality-pack/agent-metrics.json}"
_AGENT_METRICS_LOCK="${_AGENT_METRICS_LOCK:-${HOME}/.claude/quality-pack/.agent-metrics.lock}"

# with_metrics_lock: Run a command under the agent metrics file lock.
# v1.30.0 routes through _with_lockdir (PID-based stale recovery; closes
# the false-recovery race fixed for with_state_lock in v1.29.0). Public
# signature preserved.
with_metrics_lock() {
  _with_lockdir "${_AGENT_METRICS_LOCK}" "with_metrics_lock" "$@"
}

# record_agent_metric: Record an agent invocation outcome.
# Usage: record_agent_metric <agent_name> <verdict> [confidence]
# verdict: "clean" or "findings"
record_agent_metric() {
  local agent_name="$1"
  local verdict="$2"
  local confidence="${3:-0}"
  # Sanitize confidence input (may be float or non-numeric)
  confidence="${confidence%%.*}"; confidence="${confidence//[!0-9]/}"; confidence="${confidence:-0}"

  [[ -z "${agent_name}" ]] && return 0

  _do_record_metric() {
    local metrics_file="${_AGENT_METRICS_FILE}"
    local now_ts
    now_ts="$(now_epoch)"

    # Initialize if missing
    if [[ ! -f "${metrics_file}" ]]; then
      printf '{}' > "${metrics_file}"
    fi

    local current
    current="$(jq -c --arg a "${agent_name}" '.[$a] // {invocations:0, clean_verdicts:0, finding_verdicts:0, last_used_ts:0, avg_confidence:0}' "${metrics_file}" 2>/dev/null || printf '{"invocations":0,"clean_verdicts":0,"finding_verdicts":0,"last_used_ts":0,"avg_confidence":0}')"

    local invocations clean_v finding_v avg_conf
    invocations="$(jq -r '.invocations' <<<"${current}")"
    clean_v="$(jq -r '.clean_verdicts' <<<"${current}")"
    finding_v="$(jq -r '.finding_verdicts' <<<"${current}")"
    avg_conf="$(jq -r '.avg_confidence' <<<"${current}")"

    # Sanitize to integers (jq may return floats or null)
    invocations="${invocations%%.*}"; invocations="${invocations//[!0-9]/}"; invocations="${invocations:-0}"
    clean_v="${clean_v%%.*}"; clean_v="${clean_v//[!0-9]/}"; clean_v="${clean_v:-0}"
    finding_v="${finding_v%%.*}"; finding_v="${finding_v//[!0-9]/}"; finding_v="${finding_v:-0}"
    avg_conf="${avg_conf%%.*}"; avg_conf="${avg_conf//[!0-9]/}"; avg_conf="${avg_conf:-0}"

    invocations=$((invocations + 1))
    if [[ "${verdict}" == "clean" ]]; then
      clean_v=$((clean_v + 1))
    else
      finding_v=$((finding_v + 1))
    fi

    # Rolling average confidence
    if [[ "${confidence}" -gt 0 && "${invocations}" -gt 0 ]]; then
      avg_conf="$(( (avg_conf * (invocations - 1) + confidence) / invocations ))"
    fi

    local tmp_file
    tmp_file="$(mktemp "${metrics_file}.XXXXXX")"
    jq --arg a "${agent_name}" \
       --argjson inv "${invocations}" \
       --argjson cv "${clean_v}" \
       --argjson fv "${finding_v}" \
       --argjson ts "${now_ts}" \
       --argjson ac "${avg_conf}" \
       --arg pid "$(_omc_project_id 2>/dev/null || echo "unknown")" \
       '.[$a] = {invocations:$inv, clean_verdicts:$cv, finding_verdicts:$fv, last_used_ts:$ts, avg_confidence:$ac, last_project_id:$pid} | ._schema_version = 2' \
       "${metrics_file}" > "${tmp_file}" 2>/dev/null
    if ! mv "${tmp_file}" "${metrics_file}" 2>/dev/null; then
      rm -f "${tmp_file}"
    fi
  }

  with_metrics_lock _do_record_metric || true
}

# read_agent_metric: Read metrics for a specific agent.
# Returns JSON object on stdout, empty if no data.
read_agent_metric() {
  local agent_name="$1"
  [[ -f "${_AGENT_METRICS_FILE}" ]] || return 0
  jq -c --arg a "${agent_name}" '.[$a] // empty' "${_AGENT_METRICS_FILE}" 2>/dev/null || true
}

# get_all_agent_metrics: Return all agent metrics as JSON.
get_all_agent_metrics() {
  [[ -f "${_AGENT_METRICS_FILE}" ]] || { printf '{}'; return; }
  cat "${_AGENT_METRICS_FILE}" 2>/dev/null || printf '{}'
}

# --- end agent metrics ---

# --- Cross-session learning: defect pattern tracking ---
# Stored in ~/.claude/quality-pack/defect-patterns.json
# Structure: { "category": { "count": N, "last_seen_ts": N, "examples": ["desc1", ...] } }
# Categories: missing_test, type_error, null_check, edge_case, race_condition,
#   api_contract, error_handling, security, performance, docs_stale, style

_DEFECT_PATTERNS_FILE="${_DEFECT_PATTERNS_FILE:-${HOME}/.claude/quality-pack/defect-patterns.json}"
_DEFECT_PATTERNS_LOCK="${_DEFECT_PATTERNS_LOCK:-${HOME}/.claude/quality-pack/.defect-patterns.lock}"
# Cross-session lock for the resume-request claim flow (Wave 2 of the
# auto-resume harness). Distinct from with_state_lock (per-session) and
# with_metrics_lock (per-file) — the claim races across sessions
# (Wave 1 hint hook in session A vs. Wave 3 watchdog vs. /ulw-resume in
# session B), so the lock must be globally scoped, not session-scoped.
# Uses the same mkdir + stale-mtime recovery shape; a missing or stuck
# lock recovers within OMC_STATE_LOCK_STALE_SECS so a crashed claimer
# does not deadlock the resume system.
_RESUME_REQUEST_LOCK="${_RESUME_REQUEST_LOCK:-${HOME}/.claude/quality-pack/.resume-request.lock}"

# with_defect_lock: Run a command under the defect patterns file lock.
# Separate from with_metrics_lock to avoid unnecessary contention.
# v1.30.0 routes through _with_lockdir (PID-based stale recovery).
with_defect_lock() {
  _with_lockdir "${_DEFECT_PATTERNS_LOCK}" "with_defect_lock" "$@"
}

# with_resume_lock: Run a command under the resume-request claim lock.
#
# Cross-session lock — the resume-request claim races across sessions
# (Wave 1 hint hook in session A, Wave 3 watchdog daemon, and Wave 2's
# /ulw-resume claim in session B can all reach the same artifact). The
# claim sequence is read-current-state → decide-to-claim → atomic-write,
# which is non-atomic without a lock. mkdir-as-mutex + PID-based stale
# recovery (centralized in _with_lockdir) is the established pattern;
# flock is avoided because its behavior over networked filesystems is
# platform-dependent. Stale window: OMC_STATE_LOCK_STALE_SECS (default 5s,
# comfortably longer than a healthy claim — one re-read + one tmp+mv —
# and short enough that a crashed claimer does not block the system).
#
# Returns 1 (without executing) on lock-acquisition timeout. Caller
# should treat this as "claim failed; retry next tick" rather than
# "no claimable artifact". v1.30.0: routed through _with_lockdir for
# PID-based stale recovery — closes the false-recovery race for slow
# claimers parsing 100KB+ artifacts under heavy IO.
with_resume_lock() {
  _with_lockdir "${_RESUME_REQUEST_LOCK}" "with_resume_lock" "$@"
}

# _ensure_valid_defect_patterns: Validate and recover the defect-patterns file.
# If the file exists but is not valid JSON, archive it and reset to empty object.
# Uses a per-process cache to avoid re-validating on every call.
_defect_patterns_validated=0

_ensure_valid_defect_patterns() {
  [[ "${_defect_patterns_validated}" -eq 1 ]] && return 0
  _defect_patterns_validated=1
  [[ -f "${_DEFECT_PATTERNS_FILE}" ]] || return 0
  if ! jq empty "${_DEFECT_PATTERNS_FILE}" 2>/dev/null; then
    local archive
    archive="${_DEFECT_PATTERNS_FILE}.corrupt.$(date +%s)"
    cp "${_DEFECT_PATTERNS_FILE}" "${archive}" 2>/dev/null || true
    printf '{}' > "${_DEFECT_PATTERNS_FILE}"
    log_anomaly "common" "defect-patterns.json was corrupt, archived to ${archive}, reset to {}"
  fi
}

# classify_finding_category: Classify a finding description into a defect category.
# Usage: classify_finding_category "description text"
# Returns: category string on stdout
classify_finding_category() {
  local desc
  desc="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ -z "${desc}" ]] && { printf 'unknown'; return; }

  # Order matters — most specific first. Word boundaries (\b) prevent
  # collision on common words (e.g., "atomic" in "atomic CSS", "error" in
  # any finding description).
  if printf '%s' "${desc}" | grep -Eq '\b(race.?condition|concurrent|deadlock|mutex|data.?race)\b'; then
    printf 'race_condition'
  elif printf '%s' "${desc}" | grep -Eq '\b(missing.?test|no.?test|untested|test.?coverage|add.?test|no.*(unit|integration)?\s*tests?)\b|\b(tests?|spec|assert|coverage)\b'; then
    printf 'missing_test'
  elif printf '%s' "${desc}" | grep -Eq '\btype.?error\b|typescript|cast|coercion|\bNaN\b|type.?mismatch'; then
    printf 'type_error'
  elif printf '%s' "${desc}" | grep -Eq '\b(null|undefined|nil)\b.*(check|guard|safe|handle)|null.?pointer|optional.?chain'; then
    printf 'null_check'
  elif printf '%s' "${desc}" | grep -Eq '\b(edge.?case|boundary|overflow|underflow|off.by|corner.?case)\b'; then
    printf 'edge_case'
  elif printf '%s' "${desc}" | grep -Eq '\b(api|contract|schema|endpoint|payload|response).*(mismatch|break|invalid|missing)\b|\bapi\b.*\b(contract|schema)\b'; then
    printf 'api_contract'
  elif printf '%s' "${desc}" | grep -Eq '\b(unhandled|uncaught|missing).*(error|exception)\b|error.?handling|catch.*(missing|empty)|panic|abort'; then
    printf 'error_handling'
  elif printf '%s' "${desc}" | grep -Eq 'secur|auth|inject|xss|csrf|sanitiz|escap|vuln|credential|token'; then
    printf 'security'
  elif printf '%s' "${desc}" | grep -Eq 'perform|\bperf\b|slow|memory|leak|cache|optimi|latency|O\(n'; then
    printf 'performance'
  elif printf '%s' "${desc}" | grep -Eq 'visual.?design|design.?quality|gradient|palette|generic.*ui|cookie.cutter|typograph|aesthetic|spacing.*layout|color.*scheme|design.?system|design.?token|symmetrical|\btemplated\b|feature.?cards|identical.?cards|uniform.*padding|uniform.*spacing|visual.*signature|hero.*cta|cta.*hero|framework.*default|stock.?illustrat|saas.*landing'; then
    printf 'design_issues'
  elif printf '%s' "${desc}" | grep -Eq 'accessib|a11y|aria|alt.text|screen.reader|keyboard.nav|contrast.ratio|wcag|focus.ring|tab.order'; then
    printf 'accessibility'
  elif printf '%s' "${desc}" | grep -Eq 'doc|readme|comment|stale|outdated|changelog'; then
    printf 'docs_stale'
  elif printf '%s' "${desc}" | grep -Eq 'style|format|lint|naming|convention|indent'; then
    printf 'style'
  else
    printf 'unknown'
  fi
}

# record_defect_pattern: Record a defect pattern for cross-session learning.
# Usage: record_defect_pattern <category> [example_description]
record_defect_pattern() {
  local category="${1:-unknown}"
  local example="${2:-}"

  _do_record_defect() {
    local pf="${_DEFECT_PATTERNS_FILE}"
    local now_ts
    now_ts="$(now_epoch)"

    if [[ ! -f "${pf}" ]]; then
      mkdir -p "$(dirname "${pf}")"
      printf '{}' > "${pf}"
    else
      _ensure_valid_defect_patterns
    fi

    local current
    current="$(jq -c --arg c "${category}" '.[$c] // {count:0, last_seen_ts:0, examples:[]}' "${pf}" 2>/dev/null || printf '{"count":0,"last_seen_ts":0,"examples":[]}')"

    local count
    count="$(jq -r '.count' <<<"${current}")"
    count=$((count + 1))

    local tmp_file
    tmp_file="$(mktemp "${pf}.XXXXXX")"
    if [[ -n "${example}" ]]; then
      # Keep at most 5 recent examples per category
      local _pid
      _pid="$(_omc_project_id 2>/dev/null || echo "unknown")"
      jq --arg c "${category}" \
         --argjson cnt "${count}" \
         --argjson ts "${now_ts}" \
         --arg ex "${example}" \
         --arg pid "${_pid}" \
         '.[$c] = (.[$c] // {count:0,last_seen_ts:0,examples:[]}) |
          .[$c].count = $cnt |
          .[$c].last_seen_ts = $ts |
          .[$c].last_project_id = $pid |
          .[$c].examples = ((.[$c].examples + [$ex]) | .[-5:]) |
          ._schema_version = 2' \
         "${pf}" > "${tmp_file}" 2>/dev/null
      if ! mv "${tmp_file}" "${pf}" 2>/dev/null; then
        rm -f "${tmp_file}"
      fi
    else
      jq --arg c "${category}" \
         --argjson cnt "${count}" \
         --argjson ts "${now_ts}" \
         '.[$c] = (.[$c] // {count:0,last_seen_ts:0,examples:[]}) |
          .[$c].count = $cnt |
          .[$c].last_seen_ts = $ts' \
         "${pf}" > "${tmp_file}" 2>/dev/null
      if ! mv "${tmp_file}" "${pf}" 2>/dev/null; then
        rm -f "${tmp_file}"
      fi
    fi
  }

  with_defect_lock _do_record_defect || true
}

# get_top_defect_patterns: Return the top N defect categories by frequency,
# filtered to patterns seen within the last 90 days.
# Usage: get_top_defect_patterns [n] — defaults to 3
# Returns: newline-separated "category (count)" strings on stdout
get_top_defect_patterns() {
  local n="${1:-3}"
  [[ -f "${_DEFECT_PATTERNS_FILE}" ]] || return 0
  _ensure_valid_defect_patterns
  local cutoff_ts
  cutoff_ts="$(( $(now_epoch) - 90 * 86400 ))"
  jq -r --argjson n "${n}" --argjson cutoff "${cutoff_ts}" '
    to_entries |
    map(select(.key | startswith("_") | not)) |
    map(select(.value | type == "object")) |
    map(select(.value.last_seen_ts > $cutoff)) |
    sort_by(-.value.count) |
    .[0:$n] |
    .[] | "\(.key) (\(.value.count))"
  ' "${_DEFECT_PATTERNS_FILE}" 2>/dev/null || true
}

# get_defect_watch_list: Return an actionable watch-list string for injection
# into prompts. Includes concrete examples from past findings so the model
# understands WHAT to watch for, not just abstract category names.
# Filters out patterns not seen in the last 90 days.
# Usage: get_defect_watch_list [n] — defaults to 3
get_defect_watch_list() {
  local n="${1:-3}"
  [[ -f "${_DEFECT_PATTERNS_FILE}" ]] || return 0
  _ensure_valid_defect_patterns
  local list
  list="$(jq -r --argjson n "${n}" --argjson cutoff "$(( $(now_epoch) - 90 * 86400 ))" '
    to_entries |
    map(select(.key | startswith("_") | not)) |
    map(select(.value | type == "object")) |
    map(select(.value.last_seen_ts > $cutoff)) |
    sort_by(-.value.count) |
    .[0:$n] |
    map(
      .key + " ×" + (.value.count | tostring) +
      if ((.value.examples // []) | length) > 0
      then " (e.g. \"" + ((.value.examples // [])[-1] | .[0:80]) + "\")"
      else ""
      end
    ) |
    join("; ")
  ' "${_DEFECT_PATTERNS_FILE}" 2>/dev/null || true)"
  [[ -n "${list}" ]] && printf 'Watch for: %s' "${list}" || true
}

# --- end cross-session learning ---

# --- Gate skip tracking ---
#
# Records gate skips to a JSONL file for threshold tuning analysis.
# Called in the background from stop-guard.sh when a /ulw-skip is honored.

_GATE_SKIPS_FILE="${HOME}/.claude/quality-pack/gate-skips.jsonl"
_GATE_SKIPS_LOCK="${HOME}/.claude/quality-pack/.gate-skips.lock"

# with_skips_lock: Run a command under the gate-skip JSONL lock.
# v1.30.0 routes through _with_lockdir; naturally closes the v1.29.0
# sre-lens F-5 finding (silent return on exhaustion) — the helper
# emits log_anomaly with the helper-name tag for parity with sister locks.
with_skips_lock() {
  _with_lockdir "${_GATE_SKIPS_LOCK}" "with_skips_lock" "$@"
}

# with_cross_session_log_lock <log_path> <fn> [args...]
# Serialize writes to an arbitrary cross-session JSONL file. Lock dir is
# derived from the log path (<log_path>.lock) so distinct logs never
# contend with each other and the same lock site can serve any
# cross-session writer (used-archetypes.jsonl, serendipity-log.jsonl, …).
# Same mkdir + stale-recovery semantics as with_skips_lock; only the
# lock target is parameterized.
#
# Bare `printf >> file` is POSIX-atomic per write(2) only when the
# payload fits in the platform's PIPE_BUF (4 KB on Linux/macOS). JSONL
# rows from these writers are well under that, so single-row interleaves
# rarely tear bytes; the failure mode is two writers seeing the same
# pre-write file size and both deciding to append, which the kernel
# usually serializes via O_APPEND. The lock is here so the next refactor
# (rotation, batching, multi-line writes) doesn't silently regress
# correctness.
with_cross_session_log_lock() {
  local log_path="${1:-}"
  shift || true
  if [[ -z "${log_path}" ]]; then
    log_anomaly "with_cross_session_log_lock" "missing log_path argument"
    return 1
  fi
  # v1.30.0: routed through _with_lockdir. The tag embeds the log_path
  # so the anomaly emit retains the per-file diagnostic context the
  # prior implementation captured ("...attempts: ${log_path}").
  _with_lockdir "${log_path}.lock" "with_cross_session_log_lock(${log_path})" "$@"
}

record_gate_skip() {
  local reason="${1:-}"

  _do_record_skip() {
    local skip_file="${_GATE_SKIPS_FILE}"
    mkdir -p "$(dirname "${skip_file}")"
    local ts
    ts="$(now_epoch)"
    local pid
    pid="$(_omc_project_id 2>/dev/null || echo "unknown")"
    jq -nc --arg reason "${reason}" --argjson ts "${ts}" --arg project "${pid}" \
      '{ts:$ts,reason:$reason,project:$project}' >> "${skip_file}" 2>/dev/null || true
    _cap_cross_session_jsonl "${skip_file}" 200 150
  }

  with_skips_lock _do_record_skip

  # Per-session skip counter — enables outcome attribution in session_summary.jsonl
  # without re-deriving the count from gate-skips.jsonl (which lacks session_id
  # by design — projects can be shared across sessions). Locks are independent:
  # _do_record_skip uses with_skips_lock; this update uses with_state_lock and
  # never nests inside the skips lock, so deadlock is impossible.
  if [[ -n "${SESSION_ID:-}" ]]; then
    _bump_skip_count() {
      local current
      current="$(read_state "skip_count")"
      current="${current:-0}"
      write_state "skip_count" "$((current + 1))"
    }
    with_state_lock _bump_skip_count
  fi
}

# --- end gate skip tracking ---

# --- Gate event tracking (per-event outcome attribution) ---
#
# Per-session JSONL of every gate fire and finding-status change. Lets
# `/ulw-report` answer "did this gate-fire actually catch a real bug?"
# at the per-event grain instead of the per-session aggregate that
# session_summary.jsonl captures. Schema:
#
#   {ts, gate, event, block_count, block_cap, details}
#
# Where `event` is one of:
#   - "block"                  — gate emitted a decision:block JSON
#   - "finding-status-change"  — record-finding-list.sh status updated a finding
#   - "wave-status-change"     — record-finding-list.sh wave-status updated a wave
#
# Reserved-for-future tokens that no caller emits today (emitter sites
# would extend this list): "release" (gate cap reached, fall-through),
# "skip" (/ulw-skip honored bypass).
#
# `block_count` and `block_cap` are conditional — present only on `block`
# events; status-change events omit them by design (no block to count).
# When present they are JSON numbers, not strings.
#
# `details` is a JSON object for gate-specific context. Values are typed
# best-effort: keys whose value matches `^[0-9]+$` round-trip as JSON
# numbers (via --argjson); other values are JSON strings (via --arg).
# Per-gate `details` shape (current emitters):
#   discovered-scope: pending_count, wave_total, waves_completed (numbers)
#   advisory: (none)
#   session-handoff: (none)
#   review-coverage: missing_dims, next_reviewer (strings); done_dims, total_dims (numbers)
#   excellence: edited_count (number)
#   quality: missing_review, missing_verify, verify_failed,
#            verify_low_confidence, review_unremediated (numbers)
#   pretool-intent: intent (string), block_count (number), denied_segment (string)
#   finding-status: finding_id, finding_status, commit_sha (strings)
#   wave-status: wave_idx (number), wave_status, commit_sha (strings)
#
# The cross-session sweep in sweep_stale_sessions copies these rows to a
# global ledger for trend reporting; per-session cap is
# OMC_GATE_EVENTS_PER_SESSION_MAX (default 500) to prevent runaway logs
# in pathological sessions.
#
# Failure mode: never throws. Missing SESSION_ID, missing jq, broken
# session dir → silent no-op. The gate's primary path (block-or-release)
# must not depend on telemetry succeeding.

record_gate_event() {
  local gate="${1:-}"
  local event="${2:-}"
  shift 2 || true

  [[ -z "${gate}" || -z "${event}" ]] && return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  # Remaining args are key=value pairs. Recognized top-level keys:
  # block_count, block_cap. Everything else lands under .details.
  # Values that parse as non-negative integers are passed via --argjson
  # so they round-trip as JSON numbers, not strings — keeping numeric
  # aggregations like `map(.details.pending_count) | add` honest. Any
  # value that does not match `^[0-9]+$` falls back to --arg (string).
  local block_count="" block_cap=""
  local details_args=()
  local kv key value
  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    case "${key}" in
      block_count) block_count="${value}" ;;
      block_cap)   block_cap="${value}"   ;;
      *)
        if [[ "${value}" =~ ^[0-9]+$ ]]; then
          details_args+=(--argjson "${key}" "${value}")
        else
          details_args+=(--arg "${key}" "${value}")
        fi
        ;;
    esac
  done

  # Build .details — only include if at least one detail key was passed.
  local details_json='{}'
  if [[ "${#details_args[@]}" -gt 0 ]]; then
    # Build object dynamically: jq -n with --arg / --argjson pairs and a
    # $ARGS.named reduction. Bash 3.2-compatible. ARGS.named merges both
    # --arg (string) and --argjson (parsed JSON) keys.
    local jq_filter='$ARGS.named'
    details_json="$(jq -nc "${details_args[@]}" "${jq_filter}" 2>/dev/null || printf '{}')"
  fi

  local row
  row="$(jq -nc \
    --argjson ts "$(now_epoch)" \
    --arg gate "${gate}" \
    --arg event "${event}" \
    --arg block_count "${block_count}" \
    --arg block_cap "${block_cap}" \
    --argjson details "${details_json}" \
    '{ts:$ts,gate:$gate,event:$event} +
     (if $block_count != "" then {block_count:($block_count|tonumber? // 0)} else {} end) +
     (if $block_cap != "" then {block_cap:($block_cap|tonumber? // 0)} else {} end) +
     {details:$details}' 2>/dev/null)"

  [[ -z "${row}" ]] && return 0

  local cap="${OMC_GATE_EVENTS_PER_SESSION_MAX:-500}"
  append_limited_state "gate_events.jsonl" "${row}" "${cap}" 2>/dev/null || true
}

# --- end gate event tracking ---

# --- Project identity ---
#
# Generates a short hash of $PWD for use in cross-session data stores.
# Allows filtering cross-session metrics by project without storing full paths.

_omc_project_id() {
  printf '%s' "${PWD}" | shasum -a 256 2>/dev/null | cut -c1-12
}

# _omc_project_key
# Stable cross-session identifier for the current project, preferring the
# git remote (worktree-stable, survives clones at different paths) and
# falling back to _omc_project_id (PWD hash) when no git remote is
# available. The remote URL is normalized — scheme/auth stripped, SCP
# form folded into URL form, trailing `.git` removed, lowercased — so
# `https://github.com/Foo/Bar.git` and `git@github.com:foo/bar.git`
# resolve to the same key.
#
# Closes the v1.14.0 Serendipity finding's adjacent risk: cwd-hashed
# project keys diverge across worktrees (`~/repo/main` vs
# `~/repo/worktrees/feature-x`) for the same upstream project.
_omc_project_key() {
  if command -v git >/dev/null 2>&1; then
    local remote_url
    remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
    if [[ -n "${remote_url}" ]]; then
      local norm="${remote_url}"
      if [[ "${norm}" =~ ^[a-zA-Z][a-zA-Z+.-]*:// ]]; then
        # URL form: scheme://[user[:pass]@]host[:port]/path. Strip
        # scheme + auth, then collapse `:PORT/` and `:PORT$` so
        # `ssh://git@host:2222/path` and `git@host:path` reduce to
        # the same `host/path` after the SCP branch's `:` → `/` fold.
        norm="$(printf '%s' "${norm}" | sed -E 's|^[a-zA-Z][a-zA-Z+.-]*://([^/@]*@)?||; s|:[0-9]+(/\|$)|\1|')"
      else
        # SCP form: user@host:path → host/path
        norm="$(printf '%s' "${norm}" | sed -E 's|^[^@]+@||; s|:|/|')"
      fi
      norm="$(printf '%s' "${norm}" | sed -E 's|\.git/?$||; s|/+$||' | tr '[:upper:]' '[:lower:]')"
      printf '%s' "${norm}" | shasum -a 256 2>/dev/null | cut -c1-12
      return 0
    fi
  fi
  _omc_project_id
}

# recent_archetypes_for_project [N]
# Emits the up-to-N most-recent unique archetype names that have been
# used in the current project (per `_omc_project_key`), newest first,
# one per line. Default N=5. Empty output when the log is missing, the
# project has no priors, or jq/awk fail.
#
# Used by prompt-intent-router.sh to inject an anti-anchoring advisory
# ("you've used Stripe and Linear in this project — pick differently")
# when the design router fires and the same project already has
# archetype priors.
recent_archetypes_for_project() {
  local n="${1:-5}"
  local log="${HOME}/.claude/quality-pack/used-archetypes.jsonl"
  [[ -f "${log}" ]] || return 0
  local key
  key="$(_omc_project_key 2>/dev/null || true)"
  [[ -z "${key}" ]] && return 0

  jq -r --arg k "${key}" 'select(.project_key == $k) | .archetype // empty' "${log}" 2>/dev/null \
    | awk -v n="${n}" '
        NF { rows[NR] = $0; total = NR }
        END {
          seen_count = 0
          for (i = total; i >= 1 && seen_count < n; i--) {
            if (!(rows[i] in seen)) {
              seen[rows[i]] = 1
              print rows[i]
              seen_count++
            }
          }
        }
      '
}

# --- end project identity ---

# --- Project profile detection ---

# _detect_swift_target_platform: Scan a Swift project for AppKit/UIKit imports
# and macOS-only SwiftUI markers to disambiguate iOS vs macOS targets.
# Returns "ios", "macos", or empty string when target cannot be determined.
# Bounded by --include='*.swift' so the scan stops quickly on huge projects;
# excludes common build/dependency dirs that would slow the scan and emit
# noise from vendored code. Empty result means the caller should default to
# iOS (higher base rate for Swift apps).
_detect_swift_target_platform() {
  local project_dir="$1"
  local exclude_args=(
    --exclude-dir='.git' --exclude-dir='.build' --exclude-dir='build'
    --exclude-dir='node_modules' --exclude-dir='Pods' --exclude-dir='Carthage'
    --exclude-dir='DerivedData'
  )

  # Mac Catalyst override — a Catalyst target imports UIKit but ships on
  # macOS, so the import scan alone would tag it as swift-ios. Detect via
  # Info.plist's UIApplicationSupportsMacCatalyst key or Package.swift's
  # .macCatalyst platform declaration before falling through to imports.
  if grep -rlE 'UIApplicationSupportsMacCatalyst' \
      --include='*.plist' "${exclude_args[@]}" "${project_dir}" 2>/dev/null \
      | head -1 | grep -q .; then
    log_anomaly "swift_target=macos reason=catalyst_plist" 2>/dev/null || true
    printf 'macos'; return
  fi
  if [[ -f "${project_dir}/Package.swift" ]] \
      && grep -qE '\.macCatalyst\b' "${project_dir}/Package.swift" 2>/dev/null; then
    log_anomaly "swift_target=macos reason=catalyst_package_swift" 2>/dev/null || true
    printf 'macos'; return
  fi

  # Multi-target precedence: AppKit/Cocoa wins over UIKit when both are
  # present (a project with separate Mac/iOS targets routes to macOS so
  # macOS-specific guidance is surfaced; iOS guidance is the safer fallback
  # for the iOS target). The ordering is load-bearing — see test fixture.
  if grep -rlE '^[[:space:]]*import[[:space:]]+(AppKit|Cocoa)\b' \
      --include='*.swift' "${exclude_args[@]}" "${project_dir}" 2>/dev/null \
      | head -1 | grep -q .; then
    log_anomaly "swift_target=macos reason=appkit_import" 2>/dev/null || true
    printf 'macos'; return
  fi
  if grep -rlE '^[[:space:]]*import[[:space:]]+UIKit\b' \
      --include='*.swift' "${exclude_args[@]}" "${project_dir}" 2>/dev/null \
      | head -1 | grep -q .; then
    log_anomaly "swift_target=ios reason=uikit_import" 2>/dev/null || true
    printf 'ios'; return
  fi
  # Pure-SwiftUI project — no UIKit/AppKit/Cocoa imports. Check for
  # macOS-only API markers; pure SwiftUI projects with these are macOS.
  if grep -rlE '\bMenuBarExtra\b|\bNSHostingView\b|\bNSApplicationDelegate\b' \
      --include='*.swift' "${exclude_args[@]}" "${project_dir}" 2>/dev/null \
      | head -1 | grep -q .; then
    log_anomaly "swift_target=macos reason=swiftui_macos_marker" 2>/dev/null || true
    printf 'macos'; return
  fi
  # Empty: caller defaults to iOS.
  log_anomaly "swift_target=unknown reason=no_signals" 2>/dev/null || true
}

# detect_project_profile: Scan the project directory for stack indicators.
# Returns a comma-separated list of stack tags on stdout, e.g.:
#   "node,typescript,react,tailwind"
# Used to boost domain scoring and inform dimension ordering.
# Result is cached in session state as "project_profile".
detect_project_profile() {
  local project_dir="${1:-.}"
  local tags=""

  _add_tag() { tags="${tags:+${tags},}$1"; }

  # Node.js ecosystem
  [[ -f "${project_dir}/package.json" ]] && _add_tag "node"
  [[ -f "${project_dir}/tsconfig.json" ]] && _add_tag "typescript"
  [[ -f "${project_dir}/bun.lockb" ]] && _add_tag "bun"

  # Frontend frameworks (check package.json dependencies)
  if [[ -f "${project_dir}/package.json" ]]; then
    local deps
    deps="$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' "${project_dir}/package.json" 2>/dev/null || true)"
    if [[ -n "${deps}" ]]; then
      printf '%s' "${deps}" | grep -q '^react$' && _add_tag "react"
      printf '%s' "${deps}" | grep -q '^vue$' && _add_tag "vue"
      printf '%s' "${deps}" | grep -q '^svelte$' && _add_tag "svelte"
      printf '%s' "${deps}" | grep -q '^next$' && _add_tag "next"
      printf '%s' "${deps}" | grep -q '^nuxt$' && _add_tag "nuxt"
      printf '%s' "${deps}" | grep -q '^tailwindcss$' && _add_tag "tailwind"
      printf '%s' "${deps}" | grep -qE '^(vitest|jest|mocha)$' && _add_tag "js-test"
    fi
  fi

  # Python ecosystem
  [[ -f "${project_dir}/pyproject.toml" ]] && _add_tag "python"
  [[ -f "${project_dir}/setup.py" ]] && _add_tag "python"
  [[ -f "${project_dir}/requirements.txt" ]] && _add_tag "python"

  # Rust
  [[ -f "${project_dir}/Cargo.toml" ]] && _add_tag "rust"

  # Go
  [[ -f "${project_dir}/go.mod" ]] && _add_tag "go"

  # Ruby
  [[ -f "${project_dir}/Gemfile" ]] && _add_tag "ruby"

  # Elixir
  [[ -f "${project_dir}/mix.exs" ]] && _add_tag "elixir"

  # Swift / iOS / macOS — emit a "swift" tag for any Swift project, plus a
  # "swift-ios" or "swift-macos" subtype when the target platform can be
  # determined from imports. The subtype is the load-bearing signal for
  # UI routing: without it, infer_ui_platform's profile fallback could not
  # distinguish iOS from macOS Swift projects and defaulted to web.
  if ls "${project_dir}"/*.xcodeproj &>/dev/null 2>&1 || ls "${project_dir}"/*.xcworkspace &>/dev/null 2>&1 \
    || [[ -f "${project_dir}/Package.swift" ]]; then
    _add_tag "swift"
    local _swift_target
    _swift_target="$(_detect_swift_target_platform "${project_dir}" 2>/dev/null || true)"
    if [[ -n "${_swift_target}" ]]; then
      _add_tag "swift-${_swift_target}"
    fi
  fi

  # Docker / Infrastructure
  if [[ -f "${project_dir}/Dockerfile" ]] || [[ -f "${project_dir}/docker-compose.yml" ]] \
    || [[ -f "${project_dir}/docker-compose.yaml" ]]; then
    _add_tag "docker"
  fi
  if [[ -d "${project_dir}/terraform" ]] || [[ -f "${project_dir}/main.tf" ]]; then
    _add_tag "terraform"
  fi
  if [[ -f "${project_dir}/ansible.cfg" ]] || [[ -d "${project_dir}/playbooks" ]]; then
    _add_tag "ansible"
  fi

  # Shell-heavy projects
  local sh_count=0
  sh_count="$(find "${project_dir}" -maxdepth 2 -name '*.sh' -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
  [[ "${sh_count}" -ge 3 ]] && _add_tag "shell"

  # Documentation-heavy (README, docs/)
  [[ -d "${project_dir}/docs" ]] && _add_tag "docs"

  # UI presence indicators
  if [[ -d "${project_dir}/src/components" ]] \
    || [[ -d "${project_dir}/app/components" ]] \
    || [[ -d "${project_dir}/components" ]] \
    || ls "${project_dir}"/src/**/*.css &>/dev/null 2>&1 \
    || ls "${project_dir}"/src/**/*.scss &>/dev/null 2>&1; then
    _add_tag "ui"
  fi

  printf '%s' "${tags}"
}

# classify_project_maturity: Emit a coarse maturity tag for the current
# project so advisory framing branches on whether the project is brand
# new vs. polish-saturated. The tag is informational only — it does not
# gate features, just biases framing. A polish-saturated project gets
# "what's the next strategic move?" rather than a ship-readiness checklist.
#
# Heuristic combines three signals (each cheap to compute and stable):
#   1. git commit count           — strongest single signal of project age
#   2. test file count            — proxy for engineering investment
#   3. MEMORY.md line count       — proxy for cross-session memory depth
#                                   (auto-memory rule appends one entry per
#                                   substantial session, so depth ≈ prior
#                                   session count)
#
# Returns one of:
#   prototype        — < 30 commits or no signals
#   shipping         — 30–199 commits
#   mature           — 200+ commits AND 100+ tests
#   polish-saturated — 300+ commits AND 300+ tests AND 10+ MEMORY.md lines
#   unknown          — not a git repo or git unavailable
#
# Thresholds are heuristic and tuned to bias framing usefully without
# false-positive on small starter repos. Fine-grained dial-in can come
# later — this is meant as a coarse signal, not a precise classifier.
classify_project_maturity() {
  local project_dir="${1:-.}"
  local commits=0 tests=0 memory_lines=0

  # Git commit count — the strongest single signal of project age.
  if command -v git >/dev/null 2>&1 \
      && git -C "${project_dir}" rev-parse --git-dir >/dev/null 2>&1; then
    commits="$(git -C "${project_dir}" rev-list --count HEAD 2>/dev/null || echo 0)"
  fi

  # Test file count — sum across common test directories and naming
  # patterns. Bounded by directory existence so we don't scan whole-repo.
  local d count
  for d in "${project_dir}/tests" "${project_dir}/test" "${project_dir}/__tests__" \
           "${project_dir}/spec" "${project_dir}/Tests"; do
    [[ -d "${d}" ]] || continue
    count="$(find "${d}" -type f \( \
        -name 'test_*.py' -o -name '*_test.py' \
        -o -name '*.test.*' -o -name '*.spec.*' \
        -o -name 'test-*.sh' -o -name 'test_*.sh' \
        -o -name '*Tests.swift' -o -name '*Test.kt' \
        -o -name '*Test.java' -o -name '*_test.go' \
      \) 2>/dev/null | wc -l | tr -d '[:space:]')"
    tests=$((tests + count))
  done

  # MEMORY.md line count — proxy for cross-session memory depth. Path
  # encoding follows Claude Code's convention: cwd → cwd with `/` → `-`.
  local pwd_abs
  pwd_abs="$(cd "${project_dir}" 2>/dev/null && pwd || printf '')"
  if [[ -n "${pwd_abs}" ]]; then
    local encoded_cwd
    encoded_cwd="$(printf '%s' "${pwd_abs}" | tr '/' '-')"
    local memory_file="${HOME}/.claude/projects/${encoded_cwd}/memory/MEMORY.md"
    if [[ -f "${memory_file}" ]]; then
      memory_lines="$(wc -l < "${memory_file}" 2>/dev/null | tr -d '[:space:]' || printf '0')"
    fi
  fi

  # Classification thresholds. Combine signals so a single outlier
  # dimension doesn't push a project up too aggressively (e.g. a
  # 5-commit prototype with 200 generated test stubs should NOT tag mature).
  if [[ "${commits}" -ge 300 && "${tests}" -ge 300 && "${memory_lines}" -ge 10 ]]; then
    printf 'polish-saturated'
  elif [[ "${commits}" -ge 200 && "${tests}" -ge 100 ]]; then
    printf 'mature'
  elif [[ "${commits}" -ge 30 ]]; then
    printf 'shipping'
  elif [[ "${commits}" -gt 0 ]]; then
    printf 'prototype'
  else
    printf 'unknown'
  fi
}

# get_project_maturity: Cached wrapper around classify_project_maturity.
# Reads from session state first; if missing, classifies and caches.
# Like get_project_profile, the maturity is a property of the project
# (not the prompt), so once-per-session is the right cache granularity.
#
# Cache lifetime is intentionally session-bound — maturity changes
# slowly relative to a single session, so re-computing every prompt
# would burn CPU without changing behavior in practice. If a long
# session lands enough commits/tests to push a project across a
# threshold (e.g. prototype → shipping), the new tag picks up next
# session. Users debugging "why is my prototype tag stuck" should
# look here first.
get_project_maturity() {
  local cached
  cached="$(read_state "project_maturity" 2>/dev/null || true)"
  if [[ -n "${cached}" ]]; then
    printf '%s' "${cached}"
    return
  fi

  local maturity
  maturity="$(classify_project_maturity "." 2>/dev/null || true)"
  if [[ -n "${maturity}" ]]; then
    with_state_lock write_state "project_maturity" "${maturity}"
  fi
  printf '%s' "${maturity}"
}

# get_project_profile: Cached wrapper around detect_project_profile.
# Reads from session state first; if missing, detects and caches.
get_project_profile() {
  local cached
  cached="$(read_state "project_profile" 2>/dev/null || true)"
  if [[ -n "${cached}" ]]; then
    printf '%s' "${cached}"
    return
  fi

  local profile
  profile="$(detect_project_profile "." 2>/dev/null || true)"
  if [[ -n "${profile}" ]]; then
    with_state_lock write_state "project_profile" "${profile}"
  fi
  printf '%s' "${profile}"
}

# project_profile_has: Check if a project profile contains a specific tag.
# Usage: project_profile_has "react" "$profile" && ...
project_profile_has() {
  local tag="$1"
  local profile="${2:-}"
  [[ ",${profile}," == *",${tag},"* ]]
}

# --- end project profile ---

is_checkpoint_request() {
  local text="$1"

  # v1.27.0 (F-020): Phase 3 below calls is_imperative_request, which lives
  # in lib/classifier.sh. When the caller opted out of eager classifier
  # source via OMC_LAZY_CLASSIFIER=1, ensure-load it now.
  _omc_load_classifier

  # ── Phase 1: position-independent unambiguous signals ──
  # These fire BEFORE the imperative guard because they are always checkpoint,
  # even when embedded after an imperative verb (e.g., "Fix the bug, then
  # stop here"). "stop here" and "pause here" are explicit session-control
  # directives — the user IS asking to stop regardless of context.
  grep -Eiq '\b(checkpoint|pause here|stop here|let.s stop here|one wave at a time|one phase at a time|wave [0-9]+ only|phase [0-9]+ only|first wave only|first phase only|just wave [0-9]+|just phase [0-9]+)\b' <<<"${text}" \
    && return 0

  # ── Phase 2: start-of-text checkpoint phrases ──
  # Fire before the imperative guard because "stop for now" is checkpoint
  # even though "stop" is also an imperative verb.
  if [[ "${text}" =~ ^[[:space:]]*(stop|pause|hold)[[:space:]]+(for[[:space:]]+now) ]]; then
    return 0
  fi
  # Specific stop/pause compound phrases at start of text
  if grep -Eiq '^[[:space:]]*(that.s enough|that.s all|that.s good|wrap up|leave it|park it|park this)\s+for\s+now\b' <<<"${text}"; then
    return 0
  fi
  # "let's stop here" at start (also caught by Phase 1, but explicit for clarity)
  if grep -Eiq '^[[:space:]]*(let.s stop here|let.s pause here)\b' <<<"${text}"; then
    return 0
  fi

  # ── Phase 3: imperative guard ──
  # An explicit imperative at the top of the prompt beats any remaining
  # embedded checkpoint keywords. Without this, "Fix X … unchanged for now"
  # is wrongly routed to checkpoint instead of execution.
  if is_imperative_request "${text}"; then
    return 1
  fi

  # ── Phase 4: end-of-text checkpoint signals ──
  # Only fire for non-imperative prompts (guard already filtered above).
  # Require stop/pause verb context before "for now" to avoid matching
  # scope-qualifiers like "remain unchanged for now".
  if grep -Eiq '\b(stop|pause|done|halt|hold)\s+for\s+now[.!]?[[:space:]]*$' <<<"${text}"; then
    return 0
  fi
  if grep -Eiq '\b(that.s enough|that.s all|that.s good|wrap up|leave it|park it)\s+for\s+now[.!]?[[:space:]]*$' <<<"${text}"; then
    return 0
  fi

  # ── Phase 5: boundary-scoped ambiguous keywords ──
  # Scope to first/last 200 chars to prevent embedded occurrences from triggering.
  local head="${text:0:200}"
  local tail="${text: -200}"
  if grep -Eiq '\b(continue later|pick up later|resume later)\b' <<<"${head}${tail}"; then
    return 0
  fi

  # Note: "for this session" removed — already covered by
  # is_session_management_request with stronger guards (imperative guard +
  # dual-gate + 400-char head scope).

  return 1
}

is_session_management_request() {
  local text="$1"

  # v1.27.0 (F-020): is_imperative_request lives in lib/classifier.sh. When
  # the caller opted out of eager classifier source via OMC_LAZY_CLASSIFIER=1,
  # ensure-load it now so the function is defined before we call it.
  _omc_load_classifier

  # An explicit imperative at the top of the prompt beats any embedded SM
  # keywords. Without this, a prompt like "Please evaluate ..." whose quoted
  # body contains "this session's" + "worth fixing" gets misrouted to SM.
  if is_imperative_request "${text}"; then
    return 1
  fi

  # Scope the session-keyword scan to the first 400 chars. Real SM queries
  # state their framing near the top; embedded/quoted content later in the
  # prompt (e.g., /ulw command bodies that reference "this session") should
  # not force SM routing.
  local head="${text:0:400}"

  grep -Eiq '\b(new session|fresh session|same session|this session|continue here|continue in this session|stop here|pause here|resume later|pick up later|context budget|context window|context limit|usage limit|token limit|limit hit|compaction|compact)\b' <<<"${head}" \
    && grep -Eiq '(^[[:space:]]*(should|would|could|can|is|do|what|which|why)\b|\?|better\b|recommend\w*|prefer\b|advice\b|\bworth\s+(it|doing|trying|fixing|changing|considering|exploring|investigating|the\s+effort|a\s+)|\b(suggest\s+(we|you|i|they|an?|the|that|instead)|suggestion|suggestions|suggested|suggesting)\b)' <<<"${text}"
  # Note: SM intentionally keeps standalone "better" — the dual-gate (SM keyword
  # AND advisory framing) makes it safe here. "Is it better to start a new
  # session?" needs both "new session" + "better" to match. The standalone
  # advisory pattern removed "better" because it lacks this dual-gate protection.
}

is_advisory_request() {
  local text="$1"

  # Line-start question words and specific advisory phrases are strong signals.
  # Standalone "better" removed — too broad ("better for real users" is comparative,
  # not advisory). Covered by specific patterns: "would it be better", "is it better".
  # "worth" tightened — "net worth calculator" is not advisory. Require gerund/object.
  # "suggest" tightened — "auto-suggest feature" is not advisory. Require advisory framing.
  grep -Eiq '(^[[:space:]]*(should|would|could|can|is|do|what|which|why)\b|\?|recommend\w*|prefer\b|advice\b|tradeoff\b|tradeoffs\b|pros and cons\b|should we\b|would it be better\b|is it better\b|do you think\b|\bworth\s+(it|doing|trying|fixing|changing|considering|exploring|investigating|the\s+effort|a\s+)|\b(suggest\s+(we|you|i|they|an?|the|that|instead)|suggestion|suggestions|suggested|suggesting)\b)' <<<"${text}"
}

# Source the classifier subsystem (P0 imperative detection, P1 domain scoring,
# classify_task_intent, telemetry, misfire detection, is_execution_intent_value).
# All required helpers — project_profile_has, normalize_task_prompt,
# extract_skill_primary_task, is_continuation_request, is_checkpoint_request,
# is_session_management_request, is_advisory_request, session_file (lib),
# log_hook, log_anomaly, now_epoch, truncate_chars, trim_whitespace — are
# defined above this point.
#
# v1.27.0 (F-020): eager-load is now opt-in via OMC_LAZY_CLASSIFIER. The
# lazy loader (_omc_load_classifier above) is idempotent and is invoked
# from inside is_advisory_request / is_session_management_request, so a
# hook that opts out and later calls those functions still gets a working
# classifier with no function-not-found errors.
if [[ "${OMC_LAZY_CLASSIFIER:-0}" != "1" ]]; then
  _omc_load_classifier
fi

has_unfinished_session_handoff() {
  local text="$1"

  # v1.27.0 (F-009): tightened. Dropped four shapes that produced false
  # positives on legitimate scoping language:
  #   - "the rest" — appears in "implementing the rest now" (scoping)
  #     vs. "the rest is for next session" (handoff). Without local
  #     context the regex can't tell.
  #   - "remaining work" — same shape; "remaining work is tracked in
  #     F-042" is correct deferral, not handoff.
  #   - "pick up .* later" — "pick up where I left off later" is a
  #     legitimate user-facing offer of a future task.
  #   - "continue .* later" — same family.
  # The retained patterns all encode session-boundary hand-off shape
  # explicitly: "new session", "another session", "next wave/phase",
  # "wave/phase N is next" — phrasing that names a future invocation
  # context as the work boundary.
  grep -Eiq '\b(ready for a new session|ready for another session|continue in a new session|continue in another session|new session\b|another session\b|next wave\b|next phase\b|wave [0-9]+[^.!\n]* is next|phase [0-9]+[^.!\n]* is next)\b' <<<"${text}"
}


# --- P2: Council evaluation detection ---
# Detects broad whole-project evaluation requests that benefit from
# multi-role perspective dispatch (product, design, security, data, SRE, growth).
# Intentionally strict: must reference the project/codebase/app as a whole,
# or use holistic qualifiers, or ask "what should I improve" type questions.
# Does NOT match focused requests like "evaluate this function" or "review this PR."

# Helper for is_council_evaluation_request: detects narrowing qualifiers that
# scope a request to a specific code artifact or subsystem concept, signaling
# the request is focused rather than whole-project.
# Three tiers:
#   A: [preposition] [demonstrative] [artifact] — "in this function", "to the handler"
#   B: [this|that] [artifact] — "this function", "that endpoint" (no preposition)
#   C: [preposition] [subsystem concept] — "in error handling", "about architecture"
#      (no demonstrative needed for well-known subsystem scoping)
_has_narrow_scope() {
  local text="$1"

  # Tier A + B: preposition+demonstrative+artifact, or bare this/that+artifact
  # Note: "pr" replaced with "pull.?requests?" to avoid matching "project" via pr\w*
  grep -Eiq '(\b(to|in|from|about|with)\s+(this|the|that|my)|\b(this|that))\s+(function|method|class|module|component|endpoint|file|handler|test|route|flow|section|line|block|hook|script|page|view|query|model|schema|table|api|service|controller|middleware|error|auth|database|config|pull.?requests?|commit|branch|migration|architecture|design|handling|layer|logic|workflow|pipeline|infrastructure|deployment|navigation|layout|rendering|setup)\w*\b' <<<"${text}" \
    && return 0

  # Tier C: preposition + subsystem concept (no demonstrative required)
  # Catches "in error handling", "about authentication", "from architecture"
  grep -Eiq '\b(to|in|from|about|with)\s+(error|auth|api|security|data|cache|session|payment|frontend|backend|infrastructure|architecture|performance|reliability|deployment|navigation|rendering|logging|caching|routing|networking|authentication|authorization|observability|monitoring|testing|validation|serialization|scheduling)\w*\b' <<<"${text}" \
    && return 0

  # Tier D: Short abbreviations (too short for the \w*-suffixed artifact list)
  # "this PR", "in this PR", "that PR" — exact word match to avoid matching "project"
  grep -Eiq '(\b(to|in|from|about|with)\s+(this|the|that|my)|\b(this|that))\s+prs?\b' <<<"${text}" \
    && return 0

  return 1
}

# Helper for Pattern 5: detects when "improve" or "improvements" targets a specific
# area rather than the whole project.
# - "improvements to [non-project-word]" → scoped ("to the login flow")
# - "improvements to the project/codebase" → NOT scoped (whole-project target)
# - "review and improve the [non-project-word]" → scoped ("improve the tests")
# - "review and improve" (no object) → NOT scoped (broad intent)
_has_scoped_improve_target() {
  local text="$1"

  # "improvements to [word]" where [word] is NOT a project-level noun
  if grep -Eiq '\bimprovements?\s+to\s+' <<<"${text}" \
     && ! grep -Eiq '\bimprovements?\s+to\s+(the\s+|my\s+|our\s+)?(projects?|codebase|code.?base|app(lication)?|products?|repo(sitory)?|software|system|extensions?|sites?|websites?|platforms?|librar(y|ies)|packages?|plugins?|frameworks?|whole|entire)\b' <<<"${text}"; then
    return 0
  fi

  # "improve [the|my] [non-project-word]" — direct object after improve
  if grep -Eiq '\bimprove\s+(the|my|our|this|that)\s+\w' <<<"${text}" \
     && ! grep -Eiq '\bimprove\s+(the|my|our|this|that)\s+(projects?|codebase|code.?base|app(lication)?|products?|repo(sitory)?|software|system|extensions?|sites?|websites?|platforms?|librar(y|ies)|packages?|plugins?|frameworks?|whole|entire)\b' <<<"${text}"; then
    return 0
  fi

  # "improve [subsystem-concept]" — bare noun without determiner
  grep -Eiq '\bimprove\s+(error|auth|api|security|data|cache|session|payment|frontend|backend|infrastructure|architecture|performance|reliability|deployment|navigation|rendering|logging|caching|routing|networking|authentication|authorization|observability|monitoring|testing|validation)\w*\b' <<<"${text}" \
    && return 0

  return 1
}

is_council_evaluation_request() {
  local text="$1"

  # Pattern 1: "[evaluate|assess|audit|review] [my|the|this|our] [entire|whole]? [project|codebase|app|product|repo|extension|site|feature|capability|...]"
  # Guarded: reject if the project-level word is part of a compound noun
  # (e.g., "project manager", "project plan", "product team", "extension manager")
  # Noun list extended with `features?|capabilit(y|ies)|surfaces?|subsystems?` —
  # high-level scopes. Words like `module|component|flow|area` are intentionally
  # absent: they live in `_has_narrow_scope` Tier B as narrow-scope markers, so
  # adding them here would flip "evaluate this module" / "improve the flow" tests.
  if grep -Eiq '(evaluat|assess|audit|review|inspect|analyz)\w*\s+(my|the|this|our|entire|whole|full)\s+((\w+\s+){0,3})?(projects?|codebase|code.?base|app(lication)?|products?|repo(sitory)?|software|system|extensions?|sites?|websites?|platforms?|librar(y|ies)|packages?|plugins?|frameworks?|features?|capabilit(y|ies)|surfaces?|subsystems?)\b' <<<"${text}" \
     && ! grep -Eiq '\b(project|product)\s+(manager|management|plan|planning|structure|timeline|scope|lead|owner|director|description|proposal|requirements?|specification|charter|budget|schedule|board|team|files?|folders?|documentation|dependencies|configuration|roadmap|backlog|strategy|design|review)\b' <<<"${text}" \
     && ! grep -Eiq '\b(extension|package|plugin|site|platform|framework|library)\s+(manager|management|registry|store|marketplace|directory|map|version|settings|manifest)\b' <<<"${text}" \
     && ! grep -Eiq '\b(feature|capability|subsystem|surface)\s+(manager|management|flag|flags|toggle|toggles|request|requests|map|matrix|spec|specs|specification|specifications|plan|plans|description|descriptions|documentation|area|areas|boundary|boundaries)\b' <<<"${text}"; then
    return 0
  fi

  # Pattern 2: "[full|holistic|comprehensive] [review|evaluation|assessment]"
  grep -Eiq '\b(full|holistic|comprehensive|complete|whole|broad|overall)\s+(project\s+)?(review|evaluation|assessment|audit|analysis)\b' <<<"${text}" \
    && return 0

  # Pattern 3: "what [should I improve | needs improvement | am I missing]"
  # The "should I/we improve" sub-pattern allows up to 8 intermediary words
  # between the pronoun and "improve" so natural phrasings like "what should
  # we do next to further improve <X>" or "what should I focus on tomorrow
  # to improve <X>" match. Without this, the single-space `\s+` previously
  # required `improve` to be the literal next token, which missed common
  # real-user phrasings (see council/SKILL.md product-evaluation prompts).
  if grep -Eiq '\bwhat\s+(should\s+(i|we)(\s+\w+){0,8}\s+improve|needs?\s+(to\s+be\s+)?(improv|fix|chang)|am\s+i\s+miss|are\s+(we|the)\s+miss|could\s+(be\s+)?(improv|better))' <<<"${text}" \
     && ! _has_narrow_scope "${text}"; then
    return 0
  fi

  # Pattern 4: "[find|surface|identify] [blind spots|gaps|weaknesses|what is missing]"
  if grep -Eiq '\b(find|surface|identify|spot|uncover)\s+(blind\s+spots?|gaps?|weaknesses?|what\s+(is|are)\s+missing)\b' <<<"${text}" \
     && ! _has_narrow_scope "${text}"; then
    return 0
  fi

  # Pattern 5: "evaluate and plan" / "plan for improvements" / "review and improve"
  # Three sub-guards:
  #   a) _has_narrow_scope — rejects scoping to specific artifacts/subsystems
  #   b) "improvements to [non-project-word]" — "improvements to the login" is scoped
  #   c) "review/improve" with a direct object that's not a project-level word — scoped
  if grep -Eiq '\b(plan\s+for\s+improvements?|evaluat\w*.*and\s+(then\s+)?plan|review.*and\s+improve|evaluat\w*.*improv)\b' <<<"${text}" \
     && ! _has_narrow_scope "${text}" \
     && ! _has_scoped_improve_target "${text}"; then
    return 0
  fi

  # Pattern 6: implementation-bar marker — "make [my|the|this|our|these|all] X
  # impeccable / production-ready / world-class / polished / enterprise-grade /
  # flawless / perfect / excellent". These phrases imply whole-project quality
  # elevation; council/SKILL.md:143 already lists "make X impeccable" as a
  # Phase 8 entry marker, but without this pattern, the phrase did not trigger
  # council dispatch upstream.
  #
  # Determiner is required (my/the/this/our/these/all) so copular phrasings
  # ("make sure …", "make a perfect commit message", "make an excellent
  # README") do NOT match — those are templating instructions, not project-
  # level quality asks. _has_narrow_scope still filters Tier-B narrow targets
  # ("this function", "this method"). The (sure|certain) negative guard
  # below is belt-and-suspenders for the "make sure X is …" idiom which
  # technically matches the article "the" but should never trigger council.
  if grep -Eiq '\bmake\s+(my|the|this|our|these|all|it)\s+(\w+([[:space:]]+\w+){0,3}\s+)?(impeccable|perfect|world.?class|production.?ready|prod.?ready|production.?grade|polished|enterprise.?grade|excellent|flawless)\b' <<<"${text}" \
     && ! grep -Eiq '\bmake\s+(sure|certain)\b' <<<"${text}" \
     && ! grep -Eiq '\b(commit\s+message|pr\s+description|readme|changelog|docstring|comment|test\s+name|variable\s+name)\b' <<<"${text}" \
     && ! _has_narrow_scope "${text}"; then
    return 0
  fi

  return 1
}

# --- end P2 ---

# --- Discovered-scope tracking ---
#
# Captures findings emitted by advisory specialists (council lenses, metis,
# briefing-analyst) into a per-session JSONL file. The stop-guard reads the
# pending count to detect the "shipped 25 / deferred 8 / silently skipped 15"
# anti-pattern documented in the v1.10.0 council-completeness audit.
#
# State surface: <session>/discovered_scope.jsonl (one JSON object per line)
#   { id, source, summary, severity, status, reason, ts }
# Lifecycle: written by record-subagent-summary.sh on SubagentStop for
# whitelisted agents, read by stop-guard.sh on session stop, consumed by
# excellence-reviewer.md as a completeness checklist axis.
#
# Failure mode: heuristic extraction MUST fail open. A noisy parse that
# captures nothing is preferable to a blocked stop. All entry points wrap
# parsing in `|| true` and log_anomaly only on lock exhaustion.

# Whitelist of agent names whose output is parsed for findings. Excludes
# excellence-reviewer / quality-reviewer (those are verifiers, not
# discoverers — their findings already have dedicated dimensions). The
# v1.27.0 expansion (F-006) adds `oracle` and `abstraction-critic` —
# both surface novel issues with explicit severity-ranked output
# (oracle's "Findings first, ordered by severity"; abstraction-critic's
# wrong-shape-of-solution finding list). `quality-researcher` was
# considered and rejected: its output is research reports / next-step
# recommendations, not severity-anchored findings, so the fallback
# regex at extract_discovered_findings would treat its "1. <rec> 2.
# <rec> 3. <rec>" lists as findings and block Stop on legitimate
# research output. Implementation specialists (backend, frontend,
# fullstack, ios-*, devops, test-automation, draft-writer) are
# intentionally NOT on this list — their output describes WHAT was
# built, not WHAT was discovered, and parsing their step-by-step
# implementation reports as findings produced false-positive blocks
# in pilot runs.
discovered_scope_capture_targets() {
  printf '%s\n' \
    "metis" \
    "briefing-analyst" \
    "oracle" \
    "abstraction-critic" \
    "security-lens" \
    "data-lens" \
    "product-lens" \
    "growth-lens" \
    "sre-lens" \
    "design-lens" \
    "visual-craft-lens"
}

_severity_from_bullet() {
  local s="$1"
  if grep -Eiq '\b(critical|high|p0|severe|blocker)\b' <<<"${s}"; then
    printf 'high'
  elif grep -Eiq '\b(medium|p1|moderate|important)\b' <<<"${s}"; then
    printf 'medium'
  else
    printf 'low'
  fi
}

_finding_id() {
  local source_name="$1"
  local summary="$2"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s|%s' "${source_name}" "${summary}" \
      | shasum -a 256 2>/dev/null \
      | awk '{print substr($1,1,12)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s|%s' "${source_name}" "${summary}" \
      | sha256sum 2>/dev/null \
      | awk '{print substr($1,1,12)}'
  else
    # Fallback: deterministic hex based on cksum (much weaker but stable).
    printf '%s|%s' "${source_name}" "${summary}" \
      | cksum 2>/dev/null \
      | awk '{printf "%012x", $1}'
  fi
}

# extract_findings_json <message>
# v1.28.0 — structured-findings ingestion path. Reviewer agents that
# emit a `FINDINGS_JSON:` line are parsed deterministically rather than
# via prose heuristics. The contract:
#
#   FINDINGS_JSON: [{"severity":"high","category":"bug","file":"...",
#     "line":42,"claim":"...","evidence":"...","recommended_fix":"..."}]
#
# Single-line array. Agents emit this AFTER findings prose and BEFORE
# the VERDICT line. Multi-line JSON is intentionally NOT supported —
# single-line is robustly grep-able from a long mixed Markdown response,
# while multi-line would require state-tracking across line iteration
# and produce silent extraction failures on minor formatting errors.
#
# Required fields per finding object: severity (high|medium|low),
# category (bug|missing_test|completeness|security|performance|docs|
# integration|design|other), file (string, may be empty), line (integer
# or null), claim (string ≤140 chars), evidence (string), recommended_fix
# (string). Unknown fields are preserved (forward-compatible).
#
# Return: NDJSON to stdout (one normalized object per line). Empty when:
# no FINDINGS_JSON line present, JSON parse error, or empty array. Never
# errors — fail-open is the contract; the prose heuristic still runs.
extract_findings_json() {
  local message="$1"
  [[ -z "${message}" ]] && return 0

  # Strip fenced code blocks BEFORE grepping. Reviewer agents now carry
  # FINDINGS_JSON examples in their system prompts; an LLM that quotes
  # the example verbatim inside a ```code``` fence would otherwise inject
  # phantom findings into discovered_scope.jsonl. Same awk pre-pass that
  # extract_discovered_findings uses.
  local cleaned
  cleaned="$(printf '%s\n' "${message}" | awk '
    /^```/ { in_code = !in_code; next }
    !in_code { print }
  ')"

  # Grab the LAST FINDINGS_JSON: line that is unindented AND followed by
  # a JSON array opener (`[`). Requiring `[` narrows the match to actual
  # arrays — example text like `FINDINGS_JSON: <single-line JSON array>`
  # in prose would otherwise match.
  local json_line
  json_line="$(printf '%s\n' "${cleaned}" \
    | grep -E '^FINDINGS_JSON:[[:space:]]*\[' \
    | tail -n 1 \
    | sed -E 's/^FINDINGS_JSON:[[:space:]]*//' \
    || true)"
  [[ -z "${json_line}" ]] && return 0

  # Validate as JSON array; emit each element as NDJSON.
  printf '%s' "${json_line}" \
    | jq -c 'if type == "array" then .[] else empty end' 2>/dev/null \
    || true
}

# normalize_finding_object <ndjson_row>
# Coerces a single FINDINGS_JSON row into the canonical shape used by
# discovered_scope.jsonl and the council finding list. Missing fields
# default to safe values (severity=medium, category=other, line=null).
# This is the v1.28.0 bridge between the JSON contract and the existing
# heuristic-based pipeline — both paths converge on the same row shape.
normalize_finding_object() {
  local row="$1"
  [[ -z "${row}" ]] && return 0
  printf '%s' "${row}" | jq -c '{
    severity: (.severity // "medium" | tostring | ascii_downcase
               | if . == "critical" or . == "p0" or . == "blocker" then "high"
                 elif . == "p1" or . == "moderate" or . == "important" then "medium"
                 elif . == "p2" or . == "p3" or . == "minor" or . == "trivial" then "low"
                 else . end
               | if (. == "high" or . == "medium" or . == "low") then . else "medium" end),
    category: (.category // "other" | tostring | ascii_downcase
               | if (. == "bug" or . == "missing_test" or . == "completeness"
                     or . == "security" or . == "performance" or . == "docs"
                     or . == "integration" or . == "design" or . == "other") then .
                 else "other" end),
    file: (.file // "" | tostring),
    line: (.line // null | if . == null then null else (tonumber? // null) end),
    claim: (.claim // "" | tostring | .[0:140]),
    evidence: (.evidence // "" | tostring | .[0:600]),
    recommended_fix: (.recommended_fix // "" | tostring | .[0:600])
  }' 2>/dev/null || true
}

# count_findings_json <message>
# Convenience: returns the count of findings in the FINDINGS_JSON line,
# or empty when no line is present. Used by record-reviewer.sh to
# derive the finding count without relying on the parenthesized
# `FINDINGS (N)` count that may be missing or stale.
#
# Same fenced-block strip + `[` requirement as extract_findings_json so
# the two helpers stay consistent on what they accept. A message that
# extract reads as "no findings" must count as zero, not a phantom.
count_findings_json() {
  local message="$1"
  [[ -z "${message}" ]] && return 0
  local cleaned
  cleaned="$(printf '%s\n' "${message}" | awk '
    /^```/ { in_code = !in_code; next }
    !in_code { print }
  ')"
  local json_line
  json_line="$(printf '%s\n' "${cleaned}" \
    | grep -E '^FINDINGS_JSON:[[:space:]]*\[' \
    | tail -n 1 \
    | sed -E 's/^FINDINGS_JSON:[[:space:]]*//' \
    || true)"
  [[ -z "${json_line}" ]] && return 0
  printf '%s' "${json_line}" \
    | jq -r 'if type == "array" then length else 0 end' 2>/dev/null \
    || true
}

# extract_discovered_findings <agent_name> <message>
# Emits one JSONL row per detected bullet on stdout.
# Heuristic:
#   1. Strip fenced code blocks.
#   2. Walk markdown headings; when a heading matches a known anchor
#      (findings, risks, concerns, recommendations, unknowns, action items),
#      capture subsequent top-level numbered list items until the next
#      heading.
#   3. If anchored search yields nothing AND the body has >=3 top-level
#      numbered items, capture all of them as fallback.
# Cap output at 10 bullets per single capture.
extract_discovered_findings() {
  local agent_name="$1"
  local message="$2"
  [[ -z "${message}" ]] && return 0

  local now_ts cleaned bullets
  now_ts="$(now_epoch)"

  # v1.28.0 FAST PATH: when the agent emits a FINDINGS_JSON: line,
  # parse it directly. Each row becomes a normalized discovered_scope
  # entry with deterministic id, severity, and category (no heuristic
  # guessing required). Falls through to the prose path on parse error
  # or empty array — fail-open by design.
  local json_rows row summary severity category file line claim id
  json_rows="$(extract_findings_json "${message}")"
  if [[ -n "${json_rows}" ]]; then
    while IFS= read -r row; do
      [[ -z "${row}" ]] && continue
      local normalized
      normalized="$(normalize_finding_object "${row}")"
      [[ -z "${normalized}" ]] && continue
      severity="$(printf '%s' "${normalized}" | jq -r '.severity // "medium"')"
      category="$(printf '%s' "${normalized}" | jq -r '.category // "other"')"
      file="$(printf '%s' "${normalized}" | jq -r '.file // ""')"
      line="$(printf '%s' "${normalized}" | jq -r '.line // empty')"
      claim="$(printf '%s' "${normalized}" | jq -r '.claim // ""')"
      # Build summary as "[severity/category] claim @ file:line" — gives
      # the existing pipeline a stable single-line representation.
      if [[ -n "${file}" && -n "${line}" ]]; then
        summary="[${severity}/${category}] ${claim} @ ${file}:${line}"
      elif [[ -n "${file}" ]]; then
        summary="[${severity}/${category}] ${claim} @ ${file}"
      else
        summary="[${severity}/${category}] ${claim}"
      fi
      summary="${summary:0:240}"
      id="$(_finding_id "${agent_name}" "${summary}")"
      [[ -z "${id}" ]] && continue

      jq -nc \
        --arg id "${id}" \
        --arg src "${agent_name}" \
        --arg sum "${summary}" \
        --arg sev "${severity}" \
        --arg cat "${category}" \
        --arg ts "${now_ts}" \
        --argjson body "${normalized}" \
        '{id:$id, source:$src, summary:$sum, severity:$sev, category:$cat, status:"pending", reason:"", ts:$ts, structured:$body}' \
        2>/dev/null || continue
    done <<<"${json_rows}"
    # JSON path produced rows — do not fall through to prose heuristic.
    # The caller already received structured output via the loop above.
    return 0
  fi

  cleaned="$(printf '%s\n' "${message}" | awk '
    /^```/ { in_code = !in_code; next }
    !in_code { print }
  ')"

  # Anchor headings: case-insensitive match by lowercasing the line.
  # IGNORECASE=1 is GNU-awk-only and a silent no-op on BSD awk (macOS), so
  # tolower() is the portable approach. target_re is intentionally a single
  # alternation rather than nested groups — easier to extend.
  bullets="$(printf '%s\n' "${cleaned}" | awk '
    BEGIN {
      in_target = 0
      target_re = "(findings|concerns|issues|risks|recommendations|unknowns?|action[[:space:]]+items|blockers|gaps|opportunities|critical[[:space:]]+findings|unknown[[:space:]]+unknowns)"
    }
    /^#+[[:space:]]/ {
      if (tolower($0) ~ target_re) { in_target = 1 } else { in_target = 0 }
      next
    }
    # Capture both numbered (1. / 1) / 1:) AND dash/star/plus markers under
    # anchor headings. Specialists vary in convention — recall over precision
    # when an explicit Findings/Risks/Concerns heading is in scope.
    in_target && /^[[:space:]]*[0-9]+[.):]/ {
      sub(/^[[:space:]]*[0-9]+[.):]+[[:space:]]*/, "")
      print
      next
    }
    in_target && /^[[:space:]]*[-*+][[:space:]]/ {
      sub(/^[[:space:]]*[-*+][[:space:]]+/, "")
      print
    }
  ' || true)"

  if [[ -z "${bullets}" ]]; then
    # Fallback: capture top-level numbered list when no anchor heading exists
    # AND the message body suggests findings. Without the keyword gate the
    # extractor would capture step-by-step instructions, plan milestones,
    # and reference lists as if they were findings, producing false-positive
    # gate blocks on legitimate completion summaries.
    if grep -Eiq '\b(findings?|concerns?|issues?|risks?|problems?|bugs?|defects?|gaps?|vulnerabilit|recommendations?|severity|blocker|critical|should[[:space:]]+(fix|address|consider))\b' <<<"${cleaned}"; then
      local fallback_count
      fallback_count="$(printf '%s\n' "${cleaned}" \
        | grep -cE '^[[:space:]]*[0-9]+[.):][[:space:]]' 2>/dev/null \
        || true)"
      fallback_count="${fallback_count:-0}"
      if [[ "${fallback_count}" -ge 3 ]]; then
        bullets="$(printf '%s\n' "${cleaned}" | awk '
          /^#+[[:space:]]/ { next }
          /^[[:space:]]*[0-9]+[.):]/ {
            sub(/^[[:space:]]*[0-9]+[.):]+[[:space:]]*/, "")
            print
          }
        ' || true)"
      fi
    fi
  fi

  [[ -z "${bullets}" ]] && return 0

  local capped
  capped="$(printf '%s\n' "${bullets}" | head -n 10)"

  local line summary severity id
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    summary="$(printf '%s' "${line}" | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')"
    summary="${summary:0:240}"
    [[ -z "${summary}" ]] && continue

    severity="$(_severity_from_bullet "${summary}")"
    id="$(_finding_id "${agent_name}" "${summary}")"
    [[ -z "${id}" ]] && continue

    jq -nc \
      --arg id "${id}" \
      --arg src "${agent_name}" \
      --arg sum "${summary}" \
      --arg sev "${severity}" \
      --arg ts "${now_ts}" \
      '{id:$id, source:$src, summary:$sum, severity:$sev, status:"pending", reason:"", ts:$ts}' \
      2>/dev/null || continue
  done <<<"${capped}"
}

# --- Inline design-contract capture ---
#
# When a UI specialist (frontend-developer, ios-ui-developer) emits its
# 9-section Design Contract inline under a `## Design Contract` heading,
# capture the block to `<session>/design_contract.md` so design-reviewer
# and visual-craft-lens can read it and grade drift even when no
# project-root DESIGN.md exists. Closes the v1.14.x / v1.15.0 deferred
# "drift lens for inline-emitted contracts" gap.

# is_design_contract_emitter <agent_name>
# Returns 0 (true) when the agent is a UI specialist that emits a Design
# Contract block. Match short-form (frontend-developer) AND any plugin-
# namespaced form (e.g. plugin:foo:frontend-developer).
is_design_contract_emitter() {
  local agent="$1"
  [[ -z "${agent}" ]] && return 1
  local short="${agent##*:}"
  case "${short}" in
    frontend-developer|ios-ui-developer) return 0 ;;
    *) return 1 ;;
  esac
}

# extract_inline_design_contract <message>
# Emits the inline Design Contract block on stdout, or empty if not
# present. Matches the canonical headings:
#   ## Design Contract
#   ## Design Contract (iOS)
#   ## Design Contract: web
#   ## Design Contract — iOS
#   ## Design Contract - iOS
# The heading-end check requires either EOL (with optional whitespace)
# OR a punctuation suffix from a small allowlist `[(:—–-]` — this
# excludes natural-prose section titles like `## Design Contract
# overview` or `## Design Contracts We Considered` that previously
# spurious-matched the looser "any non-word char" regex.
#
# Captures from the heading until the next H2 (`## `) at the OUTERMOST
# level — H2-looking lines INSIDE fenced code blocks (` ```…``` `) do
# not terminate capture, since contracts often embed component-code or
# markdown examples in §4 (Component Stylings). H3+ (`### Section`)
# stays inside the block.
#
# Re-emission: when a single agent message contains MORE THAN ONE
# `## Design Contract` heading (e.g. the agent emitted a first attempt
# then revised), the LAST one wins — earlier blocks are discarded.
# This matches the per-session "latest contract wins" rule documented
# on `write_session_design_contract`.
extract_inline_design_contract() {
  local message="$1"
  [[ -z "${message}" ]] && return 0
  printf '%s\n' "${message}" | awk '
    BEGIN { capture = 0; in_fence = 0; buffer = "" }
    /^[[:space:]]*```/ {
      if (capture) {
        in_fence = !in_fence
        buffer = buffer $0 "\n"
        next
      }
    }
    /^## Design Contract([[:space:]]*[(:—–-]|[[:space:]]*$)/ {
      if (!in_fence) {
        # Reset buffer — last contract heading in the message wins.
        capture = 1
        in_fence = 0
        buffer = $0 "\n"
        next
      }
    }
    capture && !in_fence && /^## / {
      capture = 0
    }
    capture {
      buffer = buffer $0 "\n"
    }
    END {
      printf "%s", buffer
    }
  '
}

# extract_design_archetype <contract_text>
# Emits archetype names on stdout (one per line, deduped, in match
# order) when the contract names known archetype priors. Pattern: match
# against the canonical archetype set listed in prompt-intent-router.sh.
# Empty output when no known archetype is named (e.g. user wrote a
# custom direction with no archetype anchor).
#
# Order matters — multi-word archetypes are checked first and stripped
# from the working copy before single-word checks. Without longest-
# first + strip, "Linear" greedy-matches inside "Linear iOS" /
# "Linear Mac" and "Mercury" inside "Mercury Weather", polluting the
# cross-session memory with archetypes the user never named.
extract_design_archetype() {
  local contract="$1"
  [[ -z "${contract}" ]] && return 0
  # Canonical archetype list — multi-word entries (longest-shadow risk)
  # FIRST so they consume their own text before single-word shadows
  # (Mercury, Linear, Bear, …) run.
  local known_archetypes=(
    # Multi-word, longest-first.
    "Things 3 Mac" "Day One Mac" "Notion Mac" "Linear Mac" "Bear Mac"
    "Reeder Mac" "Raycast Mac" "Tot Mac" "Linear iOS"
    "Mercury Weather" "Apple Health" "Sleep Cycle" "IBM Carbon"
    "Cash App" "Day One" "CleanShot X" "Things 3" "NetNewsWire"
    # Single-word — alphabetized within source category.
    # web (15)
    "Linear" "Stripe" "Vercel" "Notion" "Apple" "Airbnb" "Spotify"
    "Tesla" "Figma" "Discord" "Raycast" "Anthropic" "Webflow"
    "Mintlify" "Supabase"
    # ios extras (single-word remainder)
    "Halide" "Bear" "Tot" "Reeder" "Telegram" "Robinhood"
    # macos extras (single-word remainder)
    "Tower" "Bartender"
    # cli/tui
    "lazygit" "fzf" "ripgrep" "bat" "btop" "helix" "fish" "starship"
    # domain extras (single-word remainder)
    "Mercury" "Calm" "Headspace" "Arc" "GitHub" "NYT" "Medium"
    "Atlassian"
  )
  local working_copy="${contract}"
  local arche placeholder
  for arche in "${known_archetypes[@]}"; do
    # Word-boundary match via fixed-string grep with -w. Suppress
    # grep exit-1 on no match.
    if grep -Fqw -- "${arche}" <<<"${working_copy}" 2>/dev/null; then
      printf '%s\n' "${arche}"
      # Strip the matched substring(s) so shorter shadows don't
      # double-match. Replace with a placeholder of equal token shape
      # to preserve word boundaries on adjacent matches.
      placeholder="$(printf '%s' "${arche}" | sed 's/[A-Za-z0-9]/_/g')"
      working_copy="${working_copy//${arche}/${placeholder}}"
    fi
  done
}

# write_session_design_contract <agent_name> <contract_text>
# Writes the contract to `<session>/design_contract.md` with a small
# frontmatter header. Atomic via temp+mv. Overwrites prior emissions
# (latest contract wins — the user may iterate on the design within a
# session). Caller must have run ensure_session_dir first.
#
# Concurrency: write is atomic per file (mktemp + mv) but NOT
# serialized across concurrent emitters. If two `frontend-developer`
# SubagentStop hooks fire concurrently (e.g. parallel sub-tasks via
# the Task tool), the last-mv wins — the same "latest contract wins"
# semantics as sequential iteration. Intentional: the user model is
# sequential design refinement, and a global lock here would introduce
# a write-stall on every UI-specialist completion. Do not add a lock
# without re-evaluating that tradeoff.
write_session_design_contract() {
  local agent="$1"
  local contract="$2"
  [[ -z "${contract}" ]] && return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  local target tmp
  target="$(session_file "design_contract.md")"
  tmp="$(mktemp "${target}.XXXXXX")" || return 1

  {
    printf -- '---\n'
    printf 'agent: %s\n' "${agent}"
    printf 'ts: %s\n' "$(now_epoch)"
    printf 'cwd: %s\n' "${PWD:-}"
    printf -- '---\n'
    printf '%s\n' "${contract}"
  } >"${tmp}"

  mv "${tmp}" "${target}"
}

# --- end inline design-contract capture ---

# with_scope_lock: serialize writes to discovered_scope.jsonl per session.
# v1.30.0 routes through _with_lockdir (PID-based stale recovery). The
# SESSION_ID guard is preserved at this wrapper layer because the
# per-session lockdir cannot be derived without it.
with_scope_lock() {
  if [[ -z "${SESSION_ID:-}" ]]; then
    return 1
  fi
  local lockdir
  lockdir="$(session_file ".scope.lock")"
  _with_lockdir "${lockdir}" "with_scope_lock" "$@"
}

# append_discovered_scope <agent_name> <jsonl_rows>
# Dedupes by id against existing rows, appends new ones, caps total at 200.
append_discovered_scope() {
  local agent_name="$1"
  local rows="$2"
  [[ -z "${rows}" ]] && return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  _do_append_scope() {
    local file existing_ids
    file="$(session_file "discovered_scope.jsonl")"

    # Invariant: existing_ids is always "|id1|id2|..." with both leading
    # and trailing pipes, so the substring check `*"|${id}|"*` matches.
    # An empty initial set must be "|", not "" — otherwise the first add
    # leaves the string as "id|" with no leading pipe and within-batch
    # duplicates slip through dedup.
    existing_ids="|"
    if [[ -f "${file}" ]]; then
      existing_ids="|$(jq -r '.id // empty' "${file}" 2>/dev/null | tr '\n' '|' || true)"
    fi

    local row row_id
    while IFS= read -r row; do
      [[ -z "${row}" ]] && continue
      row_id="$(jq -r '.id // empty' <<<"${row}" 2>/dev/null || true)"
      [[ -z "${row_id}" ]] && continue
      if [[ "${existing_ids}" != *"|${row_id}|"* ]]; then
        printf '%s\n' "${row}" >> "${file}"
        existing_ids="${existing_ids}${row_id}|"
      fi
    done <<<"${rows}"

    if [[ -f "${file}" ]]; then
      local total
      total="$(wc -l < "${file}" 2>/dev/null | tr -d '[:space:]' || echo 0)"
      total="${total:-0}"
      if [[ "${total}" -gt 200 ]]; then
        local trimmed
        trimmed="$(mktemp "${file}.XXXXXX")"
        tail -n 200 "${file}" > "${trimmed}" 2>/dev/null \
          && mv "${trimmed}" "${file}" 2>/dev/null \
          || rm -f "${trimmed}"
      fi
    fi
  }

  with_scope_lock _do_append_scope || true
}

# read_scope_count_by_status <status>
# Per-line counter that tolerates malformed JSONL rows. A single bad line
# would cause `jq -s` slurp to fail entirely, silently disabling the gate.
# Per-line parsing skips bad rows individually.
read_scope_count_by_status() {
  local target_status="$1"
  [[ -z "${target_status}" ]] && { printf '0'; return; }
  [[ -z "${SESSION_ID:-}" ]] && { printf '0'; return; }
  local file count line
  file="$(session_file "discovered_scope.jsonl")"
  [[ -f "${file}" ]] || { printf '0'; return; }
  count=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    if jq -e --arg s "${target_status}" '.status == $s' <<<"${line}" >/dev/null 2>&1; then
      count=$((count + 1))
    fi
  done < "${file}"
  printf '%s' "${count}"
}

read_pending_scope_count() {
  read_scope_count_by_status "pending"
}

read_total_scope_count() {
  [[ -z "${SESSION_ID:-}" ]] && { printf '0'; return; }
  local file count
  file="$(session_file "discovered_scope.jsonl")"
  [[ -f "${file}" ]] || { printf '0'; return; }
  count="$(wc -l < "${file}" 2>/dev/null | tr -d '[:space:]' || echo 0)"
  printf '%s' "${count:-0}"
}

# build_discovered_scope_scorecard [max_lines]
# Returns up to max_lines (default 8) pending findings, severity-ordered
# (high > medium > low). Empty stdout if none.
# Filters parseable pending lines first, then slurps for sorting — keeps
# the gate functional even when a single row is corrupted.
build_discovered_scope_scorecard() {
  [[ -z "${SESSION_ID:-}" ]] && return 0
  local file max_lines line filtered
  file="$(session_file "discovered_scope.jsonl")"
  [[ -f "${file}" ]] || return 0
  max_lines="${1:-8}"

  filtered=""
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    if jq -e '.status == "pending"' <<<"${line}" >/dev/null 2>&1; then
      filtered="${filtered}${line}
"
    fi
  done < "${file}"

  [[ -z "${filtered}" ]] && return 0

  printf '%s' "${filtered}" | jq -s -r --argjson max "${max_lines}" '
    sort_by(if .severity == "high" then 0 elif .severity == "medium" then 1 else 2 end) |
    .[0:$max] |
    map("- [\(.id[0:8])] \(.severity) · \(.source) · \(.summary[0:80])") |
    .[]
  ' 2>/dev/null || true
}

# update_scope_status <id_prefix> <status> [reason]
# Updates the row whose id starts with id_prefix. Refuses to update if the
# prefix is shorter than 6 chars or matches multiple rows (logs an anomaly
# instead) — silent wrong-row updates are worse than no update.
update_scope_status() {
  local id_prefix="$1"
  local new_status="$2"
  local new_reason="${3:-}"
  [[ -z "${id_prefix}" || -z "${new_status}" ]] && return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  if [[ "${#id_prefix}" -lt 6 ]]; then
    log_anomaly "update_scope_status" "rejected id_prefix too short: ${id_prefix} (min 6 chars)"
    return 1
  fi

  _do_update_scope() {
    local file
    file="$(session_file "discovered_scope.jsonl")"
    [[ -f "${file}" ]] || return 0

    # Pre-scan: refuse on ambiguity. Per-line parse so a malformed row
    # doesn't corrupt the count.
    local match_count=0 line row_id
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -z "${line}" ]] && continue
      row_id="$(jq -r '.id // empty' <<<"${line}" 2>/dev/null || true)"
      if [[ -n "${row_id}" && "${row_id}" == "${id_prefix}"* ]]; then
        match_count=$((match_count + 1))
      fi
    done < "${file}"

    if [[ "${match_count}" -gt 1 ]]; then
      log_anomaly "update_scope_status" "ambiguous prefix ${id_prefix} matched ${match_count} rows; no update applied"
      return 0
    fi
    if [[ "${match_count}" -eq 0 ]]; then
      return 0
    fi

    local tmp matched=0 obj
    tmp="$(mktemp "${file}.XXXXXX")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -z "${line}" ]] && continue
      obj="${line}"
      if [[ "${matched}" -eq 0 ]]; then
        row_id="$(jq -r '.id // empty' <<<"${line}" 2>/dev/null || true)"
        if [[ -n "${row_id}" && "${row_id}" == "${id_prefix}"* ]]; then
          obj="$(jq -c \
            --arg s "${new_status}" \
            --arg r "${new_reason}" \
            '.status = $s | .reason = $r' <<<"${line}" 2>/dev/null || printf '%s' "${line}")"
          matched=1
        fi
      fi
      printf '%s\n' "${obj}" >> "${tmp}"
    done < "${file}"

    mv "${tmp}" "${file}" 2>/dev/null || rm -f "${tmp}"
  }

  with_scope_lock _do_update_scope || true
}

# --- end discovered-scope tracking ---

# --- Wave plan tracking ---
#
# Reads the master finding list (`<session>/findings.json`) created by
# `record-finding-list.sh` during council Phase 8. The discovered-scope
# gate uses these helpers to raise its block cap when the model is
# legitimately working through a multi-wave implementation — without
# this, the gate releases after 2 blocks even if 30 findings remain
# pending across 5 planned waves.
#
# Failure mode: missing findings.json or malformed JSON returns 0,
# which preserves legacy 2-block behavior. Never throws.

read_active_wave_total() {
  [[ -z "${SESSION_ID:-}" ]] && { printf '0'; return 0; }
  local file
  file="$(session_file "findings.json")"
  [[ -f "${file}" ]] || { printf '0'; return 0; }
  jq -r '(.waves // []) | length' "${file}" 2>/dev/null || printf '0'
}

read_active_waves_completed() {
  [[ -z "${SESSION_ID:-}" ]] && { printf '0'; return 0; }
  local file
  file="$(session_file "findings.json")"
  [[ -f "${file}" ]] || { printf '0'; return 0; }
  jq -r '[(.waves // [])[] | select(.status == "completed")] | length' "${file}" 2>/dev/null || printf '0'
}

# read_total_findings_count — total finding count in findings.json.
# Used by the wave-shape predicate and the gate's block message.
# Returns "0" on missing file or malformed JSON (fail-open).
read_total_findings_count() {
  [[ -z "${SESSION_ID:-}" ]] && { printf '0'; return 0; }
  local file
  file="$(session_file "findings.json")"
  [[ -f "${file}" ]] || { printf '0'; return 0; }
  jq -r '(.findings // []) | length' "${file}" 2>/dev/null || printf '0'
}

# is_wave_plan_under_segmented — predicate matching the Phase 8 anti-pattern
# documented in council/SKILL.md Step 8: avg <3 findings/wave on a master
# list of ≥5 findings, with at least 2 waves planned. Single-finding-per-
# wave plans on small finding lists (<5) are NOT flagged because the rule
# allows them; same for trivial 1-wave plans.
#
# Used by:
#   stop-guard.sh — fires the wave-shape gate (block once)
#   stop-guard.sh — disables the discovered-scope cap-raise when true
#                   (closes the polarity bug where narrow plans got MORE
#                   permission to stop early per wave)
#   record-finding-list.sh assign-wave — emits a narrow-wave warning
#                                        when a freshly-assigned wave
#                                        contributes to under-segmentation
#
# Returns 0 (under-segmented) when the plan has ≥5 findings AND ≥2 waves
# AND avg <3 findings/wave. Otherwise 1.
is_wave_plan_under_segmented() {
  local total waves
  total="$(read_total_findings_count)"
  waves="$(read_active_wave_total)"

  # Missing or malformed → not under-segmented (fail-open).
  if ! [[ "${total}" =~ ^[0-9]+$ ]] || ! [[ "${waves}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  # Trivial plans (≤1 wave) or small finding lists (<5) are exempt — the
  # Phase 8 rule explicitly permits single-wave grouping on small lists.
  if [[ "${waves}" -le 1 ]] || [[ "${total}" -lt 5 ]]; then
    return 1
  fi

  # Strict average <3: fail when total < 3*waves (integer arithmetic).
  if (( total < 3 * waves )); then
    return 0
  fi
  return 1
}

# --- end wave plan tracking ---

# --- Session discovery for manually-invoked scripts ---
#
# Manually-invoked autowork scripts (record-finding-list.sh, show-status.sh)
# do not have a hook JSON to read SESSION_ID from. They must discover the
# active session by inspecting STATE_ROOT directly.
#
# Critical: filter for directories. STATE_ROOT also contains flat files
# (hooks.log, installed-manifest.txt) which would otherwise be picked by
# a naive `ls -t | head -1` and cause downstream bugs (mkdir -p collisions
# in record-finding-list.sh, "no state file" warnings in show-status.sh).
#
# Returns the session ID (basename of newest dir) or empty string if no
# session directory exists. Never throws; STATE_ROOT-missing is silent.

discover_latest_session() {
  local d newest_match="" newest_any=""
  [[ -d "${STATE_ROOT}" ]] || { printf ''; return 0; }
  shopt -s nullglob
  local dirs=("${STATE_ROOT}"/*/)
  shopt -u nullglob
  # Bash 3.2 (macOS default) treats `${dirs[@]}` on an empty array as
  # an unbound variable under `set -u`. Guard explicitly so we exit
  # cleanly when STATE_ROOT is empty.
  if [[ "${#dirs[@]}" -eq 0 ]]; then
    printf ''
    return 0
  fi
  # Prefer the newest session whose stored `cwd` matches the current
  # working directory — closes the cross-project session leak where
  # two concurrent sessions for different repos race on mtime and the
  # script discovery picks whichever was touched most recently. Fall
  # back to plain newest-mtime when no session matches the current cwd
  # (preserves the legacy behavior for sessions that predate the cwd
  # field, and for callers running outside any tracked project root).
  local current_cwd="${PWD:-}"
  for d in "${dirs[@]}"; do
    [[ -z "${newest_any}" || "${d}" -nt "${newest_any}" ]] && newest_any="${d}"
    if [[ -n "${current_cwd}" ]]; then
      local stored_cwd
      stored_cwd="$(jq -r '.cwd // empty' "${d}/${STATE_JSON}" 2>/dev/null || true)"
      if [[ -n "${stored_cwd}" && "${stored_cwd}" == "${current_cwd}" ]]; then
        [[ -z "${newest_match}" || "${d}" -nt "${newest_match}" ]] && newest_match="${d}"
      fi
    fi
  done
  if [[ -n "${newest_match}" ]]; then
    basename "${newest_match}"
  elif [[ -n "${newest_any}" ]]; then
    basename "${newest_any}"
  else
    printf ''
  fi
}

# --- end session discovery ---

# Final cleanup: unset bootstrap helpers now that all libs have been sourced.
unset _omc_self _omc_self_dir
