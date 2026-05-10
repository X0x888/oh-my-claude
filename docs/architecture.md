# Architecture

oh-my-claude is a harness that wraps Claude Code's lifecycle events with bash hooks. Every prompt, tool use, compaction, resume, and stop attempt passes through scripts that classify intent, inject context, track state, and enforce quality gates. There is no daemon, no runtime, and no external service. The entire system is bash scripts sourcing a shared library, communicating through a JSON state file.

---

## Components

### Orchestration

**`skills/autowork/SKILL.md`** -- Master skill definition. Entry point for `/ulw`, `/autowork`, `/ultrawork`, and `/sisyphus` commands. Defines thinking requirements (plan before acting, reflect after results, no mechanical tool chaining), operating rules (classify intent, classify domain, route to specialists), and execution style (incremental changes, mandatory review, no premature stopping). Sets `disable-model-invocation: true` and `model: opus`.

### Shared Library

**`skills/autowork/scripts/common.sh`** (~2,600 lines, with three subsystems extracted to `lib/`) -- Every hook script sources this file. State I/O lives in `lib/state-io.sh` (extracted in v1.12.0); prompt classification lives in `lib/classifier.sh` (extracted in v1.13.0); verification scoring (Bash + MCP) lives in `lib/verification.sh` (extracted in v1.14.0). All three libs are sourced from `common.sh` so callers see a single import surface. Together they provide:

- **JSON state management** (`lib/state-io.sh`): `write_state(key, value)`, `read_state(key)`, `write_state_batch(k1, v1, k2, v2, ...)` for atomic multi-key updates, plus `with_state_lock` / `with_state_lock_batch` for concurrent-safe read-modify-write. All operations use jq with atomic temp-file-then-mv writes to prevent corruption.
- **Verification scoring** (`lib/verification.sh`): `score_verification_confidence(cmd, output, project_test_cmd)` for Bash invocations, `score_mcp_verification_confidence(verify_type, output, has_ui_context)` for MCP tools, plus `detect_verification_method`, `classify_mcp_verification_tool`, and `detect_mcp_verification_outcome`. Pure functions over the command text and output — no state I/O.
- **Intent classification** (`lib/classifier.sh`): `classify_task_intent(text)` -- returns one of 5 categories (see classification order below). Delegates to `is_continuation_request`, `is_checkpoint_request`, `is_session_management_request`, `is_imperative_request`, and `is_advisory_request`.
- **Domain scoring** (`lib/classifier.sh`): `infer_domain(text)` -- scores prompt text against keyword lists for 6 domains (coding, writing, research, operations, mixed, general). Uses `count_keyword_matches` with grep to count occurrences. Highest score wins. "Mixed" requires coding involvement with a second domain scoring at least 40% of the primary.
- **Council evaluation detection**: `is_council_evaluation_request(text)` -- detects broad whole-project evaluation requests that benefit from multi-role perspective dispatch. Uses 5 pattern families with narrowing qualifier guards to avoid false-positives on focused requests.
- **Prompt normalization**: `normalize_task_prompt(text)` -- strips `/ulw`, `autowork`, `ultrawork`, `sisyphus`, and `ultrathink` prefixes.
- **Continuation detection**: `is_continuation_request(text)` -- matches "continue", "resume", "carry on", "keep going", "pick it back up", etc.
- **Helpers**: `truncate_chars(limit, text)`, `trim_whitespace(text)`, `now_epoch`, `is_internal_claude_path(path)`, `is_maintenance_prompt(text)`, `has_unfinished_session_handoff(text)`, `is_execution_intent_value(intent)`.

### Hook Scripts

**`quality-pack/scripts/prompt-intent-router.sh`** (~195 lines) -- **UserPromptSubmit hook**. The master context injector. For every prompt:

1. Reads session ID and prompt text from hook JSON.
2. Classifies intent via `classify_task_intent`.
3. Resets per-turn counters (`stop_guard_blocks`, `session_handoff_blocks`, `advisory_guard_blocks`, `stall_counter`).
4. Preserves or updates `current_objective` depending on intent type.
5. Appends to `recent_prompts.jsonl` (capped at 12 entries).
6. If the prompt contains an activation keyword (`ultrawork`, `ulw`, `autowork`, `sisyphus`), builds a `context_parts` array with:
   - Mode directive (continuation, advisory, session-management, checkpoint, or new execution).
   - Preserved objective and prior assistant state for continuations.
   - Recent specialist conclusions from `subagent_summaries.jsonl`.
   - Thinking directive (plan/reflect requirements).
   - Domain-specific specialist hints (coding, writing, research, operations, mixed, general).
   - Council evaluation guidance (for broad whole-project evaluation requests detected by `is_council_evaluation_request`).
7. If the prompt contains `ultrathink`, appends a deeper investigation directive.
8. Emits the assembled context via `hookSpecificOutput.additionalContext`.

**`skills/autowork/scripts/stop-guard.sh`** -- **Stop hook**. Hard quality gate that can block Claude from stopping. Seven independent checks:

1. **Advisory inspection gate**: If the task is advisory over a codebase (coding or mixed domain) and no code inspection (`last_advisory_verify_ts`) or build/test verification (`last_verify_ts`) was detected, blocks the stop. Cap: 1 block.
2. **Session handoff gate**: If the last assistant message contains deferral language ("ready for a new session", "next wave", "next phase") and the user did not request a checkpoint, blocks the stop. Cap: 2 blocks.
3. **Review/verification gate**: If files were edited (`last_code_edit_ts` / `last_doc_edit_ts` set, or legacy `last_edit_ts` for resumed sessions) but review (`last_review_ts` for code, `last_doc_review_ts` for docs) or verification (`last_verify_ts`) are missing or stale, blocks the stop. Doc-only edits route to `editor-critic` instead of `quality-reviewer` and skip the verification requirement. Verification is only checked for coding and mixed domains. Cap: 3 blocks. Block 1 uses the full verbose "FIRST self-assess" message; blocks 2+ use a concise "Still missing: X. Next: Y." form that names only un-ticked items.
4. **Dimension gate**: After the standard review/verify gate passes, a prescribed review sequence is enforced on complex tasks via per-dimension ticks. On each block, the gate message names the specific next reviewer to run rather than making the agent guess.

    - **Trigger**: session has `dimension_gate_file_count`+ unique edited files (default 3, configurable). Below the threshold, the gate is inert.
    - **Required dimensions** (computed from the edit mix):
        - Any code files → `bug_hunt`, `code_quality`, `stress_test`, `completeness`
        - Any UI files (`.tsx`, `.jsx`, `.vue`, `.svelte`, `.astro`, `.css`, `.scss`, `.sass`, `.less`, `.styl`, `.html`, `.htm`) → add `design_quality`
        - Any doc files → add `prose`
        - At least `traceability_file_count`+ files (default 6) → add `traceability`
    - **Dimension ownership** (one reviewer per dimension; see `AGENTS.md` §"Dimension mapping"):
        - `quality-reviewer` → `bug_hunt`, `code_quality`
        - `metis` → `stress_test`
        - `excellence-reviewer` → `completeness`
        - `design-reviewer` → `design_quality`
        - `editor-critic` → `prose`
        - `briefing-analyst` → `traceability`
    - **Validity**: each tick is timestamped (`dim_<name>_ts`) and considered valid only if the tick epoch is ≥ the relevant edit clock (`last_code_edit_ts` for most dimensions, `last_doc_edit_ts` for `prose`). A post-tick edit implicitly invalidates the dimension without needing explicit clearing.
    - **Resumed sessions**: sessions resumed from pre-dimension-gate state get one free stop (`dimension_resume_grace_used`) before the gate starts enforcing.
    - **Cap**: 3 blocks (`dimension_guard_blocks`). Exhaustion records `dimensions_missing=...` in `guard_exhausted_detail` and falls through to the excellence gate rather than bypassing all checks.
5. **Excellence gate**: After all earlier gates pass, if the session has `excellence_file_count`+ unique edited files and no `last_excellence_review_ts` has been recorded (or it is stale), blocks the stop once to request a fresh-eyes holistic evaluation via `excellence-reviewer`. Cap: 1 block (controlled by `excellence_guard_triggered` flag).
6. **Metis-on-plan gate** (opt-in): When `OMC_METIS_ON_PLAN_GATE=on` and the recorded plan is flagged high-complexity, blocks the stop until `metis` has stress-tested the current plan since `plan_ts`. Cap: 1 block per plan cycle (`metis_gate_blocks`).
7. **Final-closure gate**: After the work itself is clean, checks whether Claude's final user-facing wrap is audit-ready. Substantive sessions must end with an implementation-summary shape that tells the user what changed, how it was verified, and what remains (`Changed`/`Shipped`, `Verification`, `Next`, plus `Risks` when anything was deferred). This gate is intentionally late and style-aware enough to accept either the standard or executive closeout labels; it exists so users do not have to interrogate a "looks done" answer for basic audit facts.

The block caps prevent infinite loops. After the cap, Claude is allowed to stop even if gates are unsatisfied.

**`skills/autowork/scripts/mark-edit.sh`** -- **PostToolUse hook** for Edit, Write, and MultiEdit. Records `last_edit_ts` on every edit (backward compat) and also classifies the path via `is_doc_path`: code edits bump `last_code_edit_ts`, doc edits bump `last_doc_edit_ts`. Maintains cached `code_edit_count` / `doc_edit_count` counters (incremented only on first-time paths via `grep -Fxq` dedup). Resets all guard block counters and the stall counter. Excludes internal Claude paths (projects, state, tasks, todos, transcripts, debug) from tracking. Logs edited file paths to `edited_files.log`.

**`skills/autowork/scripts/record-verification.sh`** -- **PostToolUse hook** for Bash and MCP verification tools (Playwright browser_snapshot/take_screenshot/console_messages/network_requests/evaluate, computer-use screenshot). For Bash tools, checks if the command matches a test/build/lint pattern (npm test, cargo test, pytest, vitest, eslint, tsc, etc.). For MCP tools, classifies the tool name via `classify_mcp_verification_tool` and detects pass/fail via `detect_mcp_verification_outcome`. Records `last_verify_ts`, confidence score, and method, and resets guard counters. MCP verification base scores are below the default confidence threshold (40) — passive observations only pass the gate when output carries assertion/pass-fail signals or when recent edits include UI files (which adds a context bonus).

**`skills/autowork/scripts/record-delivery-action.sh`** -- **PostToolUse hook** for Bash delivery actions. Records successful `git commit` as commit actions and successful `git push`, `git tag`, and `gh pr/release/issue` publish-class commands as publish actions. Dry-run/read-only forms (`git commit --dry-run`, `git push --dry-run`, read-only `git tag`, `git apply --check|--stat|--numstat|--summary`) do not satisfy the contract. Feeds `stop-guard.sh` so prompt-stated commit and publish requirements are enforced by observed actions, not final-answer prose.

**`skills/autowork/scripts/record-advisory-verification.sh`** -- **PostToolUse hook** for Grep and Read. During advisory tasks, records `last_advisory_verify_ts` when a non-internal file is read or searched. Also implements stall detection: increments a counter on each Read/Grep call, and at `stall_threshold` consecutive calls (default 12, configurable via `oh-my-claude.conf`) without an edit, test, or agent delegation, injects a stall-check nudge.

**`skills/autowork/scripts/reflect-after-agent.sh`** -- **PostToolUse hook** for Agent. After an agent returns, injects a reflection prompt telling Claude to verify the agent's highest-impact claims against actual code before relying on them. For advisory tasks, additionally warns not to deliver the final report until all exploration agents have returned.

**`skills/autowork/scripts/record-reviewer.sh`** -- **SubagentStop hook** for reviewer and analysis agents (`quality-reviewer`, `editor-critic`, `excellence-reviewer`, `metis`, `briefing-analyst`, `design-reviewer`, plus `superpowers:code-reviewer` / `feature-dev:code-reviewer`). Accepts a reviewer-type argument (`standard|excellence|prose|stress_test|traceability|design_quality`) that determines which dimensions to tick. Parses a `VERDICT: CLEAN|SHIP|FINDINGS|BLOCK` line from the agent's last message (last match wins via `tail -n 1`, `FINDINGS (0)` treated as CLEAN), falling back to a legacy phrase-based regex when the VERDICT line is absent. Records `last_review_ts`, resets stop guard counters, and on clean reviews calls `tick_dimension` to mark the relevant dimension(s) valid. The excellence path additionally records `last_excellence_review_ts` and preserves `review_had_findings` from the standard review.

**`skills/autowork/scripts/record-pending-agent.sh`** -- **PreToolUse hook** for Agent. Records every agent dispatch to `pending_agents.jsonl` (capped at 32 entries) under the state lock. Used by `pre-compact-snapshot.sh` to render a "Pending Specialists (In Flight)" section, and by `session-start-compact-handoff.sh` to emit a re-dispatch directive on compact resume. Entries are removed by `record-subagent-summary.sh` on `SubagentStop` (FIFO-oldest match by `agent_type`).

**`skills/autowork/scripts/record-subagent-summary.sh`** -- **SubagentStop hook** (all agents). Appends the agent's type and last assistant message to `subagent_summaries.jsonl` (capped at 16 entries). Also removes the FIFO-oldest matching entry from `pending_agents.jsonl` via a line-by-line parser that tolerates malformed JSONL lines.

**`quality-pack/scripts/pre-compact-snapshot.sh`** -- **PreCompact hook**. Snapshots the current working state to `precompact_snapshot.md`: session ID, working directory, workflow mode, domain, intent, objective, persisted delivery contract, edited files, recent prompts, specialist conclusions, and review/verification plus remaining-obligation status.

**`quality-pack/scripts/post-compact-summary.sh`** -- **PostCompact hook**. Combines Claude's native compact summary with the preserved snapshot into `compact_handoff.md`.

**`quality-pack/scripts/session-start-resume-handoff.sh`** -- **SessionStart hook** (resume). Copies session state from the previous session's state directory to the new session. Rehydrates JSON state, JSONL files, and logs. Injects continuation context with preserved objective, domain, workflow mode, specialist conclusions, and domain-specific directives.

**`quality-pack/scripts/session-start-compact-handoff.sh`** -- **SessionStart hook** (compact). Reads the pre-compact snapshot, injects it with a continuation directive, preserved delivery contract, and remaining obligations so the compact boundary does not silently reset what "done" means.

**`quality-pack/scripts/stop-failure-handler.sh`** -- **StopFailure hook**. Captures the moment Claude Code terminates the session due to a rate cap, billing failure, auth failure, or other fatal stop. Dispatched for any matcher (`rate_limit`, `authentication_failed`, `billing_error`, `invalid_request`, `server_error`, `max_output_tokens`, `unknown`). Reads the `rate_limit_status.json` sidecar that `statusline.py` writes during the session (the StopFailure payload itself does not carry rate-limits) and persists `resume_request.json` with the original objective, last user prompt, matcher, the earliest known reset epoch, and a snapshot of the rate-limit windows. Hook output is documented as ignored by Claude Code at this event — this script is purely for side-effect persistence so a future watchdog (or the next session-resume) can act on the stop without losing context. Also appends a `stop-failure-captured` row to `gate_events.jsonl` for `/ulw-report` visibility.

**`quality-pack/scripts/resume-watchdog.sh`** -- **Headless daemon** (Wave 3 of the auto-resume harness; opt-in only). Polled by a LaunchAgent (macOS), systemd user-timer (Linux), or cron at ~2-minute cadence. Walks `STATE_ROOT/*/resume_request.json` via `find_claimable_resume_requests`. For each unclaimed artifact whose `resets_at_ts <= now - 60s` AND whose `last_attempt_ts` is outside the cooldown (`OMC_RESUME_WATCHDOG_COOLDOWN_SECS`, default 600s) AND whose `cwd` still exists AND whose payload is non-empty: atomically claims via `claim-resume-request.sh --watchdog-launch $$ --target <path>`, then launches `claude --resume <session_id> '<original prompt>'` in a detached `tmux new-session -d -s omc-resume-<sid>` rooted at the artifact's cwd. When `tmux` is unavailable, falls back to an OS notification (macOS `osascript -e 'display notification ...'` / Linux `notify-send`) and does NOT claim — the user invokes `/ulw-resume` manually after seeing the alert. Stateless and idempotent (cap of 1 launch per tick prevents resume storms; per-artifact cooldown prevents repeated launches; per-artifact attempt cap of 3 enforced by the claim helper prevents infinite retries when each launched session itself rate-limits). Default OFF — meaningful behavior change requires opt-in via `bundle/dot-claude/install-resume-watchdog.sh`. Privacy: gated by both `is_stop_failure_capture_enabled` and `is_resume_watchdog_enabled`; opt-out at either layer makes the watchdog a no-op. Emits `resume-watchdog.{tick-complete,launched-tmux,notified-no-tmux,skipped-cooldown,skipped-future-reset,skipped-missing-cwd,skipped-empty-payload,claim-failed,tmux-launch-failed-reverted,tmux-launch-failed-revert-failed}` rows to `gate_events.jsonl` for `/ulw-report` visibility. When `launch_in_tmux` fails after a successful claim, the watchdog reverts the claim under the cross-session lock so the next tick re-evaluates the artifact from a clean slate (otherwise the cooldown would block retry for `OMC_RESUME_WATCHDOG_COOLDOWN_SECS` despite the user's tmux/claude path possibly recovering seconds later); `tmux-launch-failed-reverted` confirms a healthy revert, `tmux-launch-failed-revert-failed` surfaces the rare unhealed-state case (lock contention + read-only mount + malformed artifact) where manual cleanup is required. Logs go to `~/.claude/quality-pack/state/.watchdog-logs/resume-watchdog.{log,err}` (created by the installer). **Telemetry-path gotcha:** the watchdog runs as a daemon without a hosting session, so it sets a synthetic `SESSION_ID=_watchdog` (passes `validate_session_id`) and writes its `gate_events.jsonl` rows to `~/.claude/quality-pack/state/_watchdog/`. Without the synthetic ID, `record_gate_event` no-ops silently and the entire `resume-watchdog.*` event stream above never lands. Do not refactor this without preserving the synthetic-session-ID setup in `resume-watchdog.sh` (see lines 52-57). **Synthetic-session sidecars (v1.34.1+):** `last_tick_completed_ts` (epoch ts; written at top of every tick AND re-bumped at end — daemon-liveness heartbeat readable by `/ulw-report` / `/ulw-status` to surface "last successful tick: N min ago" and distinguish "no work to do" from "hung daemon"). Cooldown counter `total_skipped_cooldown_under_lock` (separated from `total_skipped_cooldown` in v1.34.1 so two-daemon races — LaunchAgent + manual cron — show as a distinct signal instead of folding into routine pre-check skips). Per-tick cap on the synthetic session's `gate_events.jsonl` enforced inside `resume-watchdog.sh` itself (default 500 rows, `OMC_GATE_EVENTS_PER_SESSION_MAX`) — pre-fix the cap fired only at sweep time, which never ran on watchdog-only hosts where no real claude session opened.

**`quality-pack/scripts/session-start-resume-hint.sh`** -- **SessionStart hook** (no matcher → fires on every `source` value: `startup`, `resume`, `compact`, `clear`). The consumer side of the auto-resume harness — Wave 1 of the long-running-agent harness. Walks `STATE_ROOT/*/resume_request.json` via the new `find_claimable_resume_requests` helper in `common.sh`, looking for unclaimed artifacts where `resets_at_ts <= now` (or `null` for raw-API sessions, treated as informational). Surfaces the original objective, last user prompt, matcher, and humanized reset timing as `additionalContext` so the model knows there is a pending `/ulw-resume` to claim. Per-session idempotent (writes `resume_hint_emitted=1` after first emit). Cross-session legitimately re-fires until the artifact is claimed (Wave 2's `/ulw-resume`), or until it ages past `OMC_RESUME_REQUEST_TTL_DAYS` (default 7d). Same-cwd artifacts are preferred over different-cwd artifacts; the hint labels cross-cwd matches explicitly. Privacy: `is_stop_failure_capture_enabled` is honored — opt-out at the producer (StopFailure write) implies opt-out at the consumer (this hint). Emits `session-start-resume.resume-hint-emitted` rows to `gate_events.jsonl`.

**`skills/autowork/scripts/pretool-timing.sh`** + **`skills/autowork/scripts/posttool-timing.sh`** -- Universal-matcher PreToolUse / PostToolUse hooks that capture per-tool / per-subagent durations into `<session>/timing.jsonl` for the Stop epilogue and `/ulw-time` skill. Lock-free hot path: each hook appends one sub-PIPE_BUF JSONL row per call (kernel-serialized via O_APPEND on POSIX — no `with_state_lock` cost on Read/Grep/Bash hot loops). PreTool reads `.tool_input.subagent_type` for `Agent` calls and `.tool_use_id` (when Claude Code provides it) so the aggregator can pair start/end across out-of-order parallel completions. Both hooks fast-path-out via `is_time_tracking_enabled` — opt-out is essentially free (no jq, no disk I/O). Tagged with `prompt_seq` (tracked in `session_state.json`, incremented by `prompt-intent-router.sh` on UserPromptSubmit) so the aggregator only pairs same-epoch start/end rows — pre-compaction starts cannot bind to post-compaction ends.

**`skills/autowork/scripts/stop-time-summary.sh`** -- **Stop hook** registered AFTER `stop-guard.sh` in the Stop array. When the session releases, finalizes the active prompt's walltime (idempotent: only writes a `prompt_end` row if one isn't already present for the current `prompt_seq`), aggregates the session log via `timing_aggregate`, and emits the polished `─── Time breakdown ───` card (title rule + stacked top bar + per-prompt sparkline + per-bucket rows + insight) as multi-line `systemMessage` (the documented user-visible Stop output field — Stop hooks do NOT support `hookSpecificOutput.additionalContext`; see `CLAUDE.md` "Stop hook output schema" rule) above the 5s walltime noise floor (applied in the hook, not the formatter). Self-suppresses when `gate_events.jsonl`'s tail shows an `event=block` row within the last 3 seconds — `stop-guard.sh` always exits 0 and signals via decision JSON, so the kernel-level "skip subsequent hooks on exit 2" semantics doesn't apply; the recency check on `gate_events.jsonl` is what tells the time-summary "stop-guard just blocked, don't add noise to the user's recovery message." Also writes a session rollup to `~/.claude/quality-pack/timing.jsonl` for cross-session `/ulw-report` integration; the writer dedups by `session_id` so multi-Stop sessions don't accrue inflated walltime totals. Privacy: gated by `is_time_tracking_enabled`. Emits no `gate_events.jsonl` rows itself (informational, not gating).

**`skills/autowork/scripts/lib/timing.sh`** -- Sourced by `common.sh`. Provides `timing_append_start` / `timing_append_end` / `timing_append_prompt_start` / `timing_append_prompt_end` / `timing_append_directive` capture helpers (lock-free); `timing_aggregate <log_path> [prompt_seq_filter]` jq-based pair-walker that emits per-bucket totals + per-tool/per-subagent call counts + `prompts_seq` (per-prompt durations for sparkline rendering); `timing_format_oneline` (compact inline form, used by `show-status.sh`); `timing_format_full` (polished card: title rule, stacked top-line bar with `█▒░` segment chars, per-prompt sparkline via `_timing_sparkline` for multi-prompt views, per-bucket per-row sub-bars via `_timing_render_bucket`, anomaly note, insight via `timing_generate_insight` — used by both Stop epilogue and `/ulw-time`); `timing_generate_insight <agg> [scope]` (priority-laddered one-line observation: anomaly → dominance → idle-heavy → churn → diversity → clean-run reassurance, with turn/window scope wording); `timing_record_session_summary` (cross-session writer, dedups by `session_id` on every write); `timing_xs_aggregate <cutoff_epoch>` (week/month/all rollup math); `timing_next_prompt_seq` / `timing_current_prompt_seq` / `timing_latest_finalized_prompt_seq` (prompt-epoch helpers used by the router and `last-prompt` mode). Pairing rules: `tool_use_id` exact match → LIFO for `Agent` (rare overlap) → FIFO for non-Agent tools (per-tool sums are commutative under per-call swaps). Whole-second precision via `now_epoch` is documented as a deliberate constraint — sub-second tools round to 0s but still surface via call counts. Long subagent/tool names > 22 chars truncated with U+2026 in sub-rows to maintain column alignment.

### v1.28.0 surfaces

**`skills/autowork/scripts/blindspot-inventory.sh`** -- Per-project surface scanner. Lazily walks the project root and enumerates 10 surface categories (routes, env vars, tests, docs, config flags, UI files, error states, auth paths, release steps, scripts), capping at 50 entries per category. Caches the result at `~/.claude/quality-pack/blindspots/<project_key>.json` with a 24h TTL (configurable via `blindspot_ttl_seconds` / `OMC_BLINDSPOT_TTL_SECONDS`). The cache key uses `_omc_project_key` (git-remote-first, cwd-hash fallback) so worktree clones share an inventory. Consumed by an `INTENT-BROADENING DIRECTIVE` injected by `prompt-intent-router.sh` on execution + continuation prompts (skipped on advisory / session_management / checkpoint), telling the model to surface gaps under a `**Project surfaces touched:**` opener line. Two independent flags: `blindspot_inventory` controls the scanner; `intent_broadening` controls the directive injection. Directive renders without an inventory path reference when only `intent_broadening=on`. Privacy: persists file paths and variable NAMES (extracted from `process.env.X`, `os.getenv("X")`, `${BASH_VAR}` references) — never reads file contents or env values; `.env*` files are recorded as paths only. Refresh on demand: `bash ~/.claude/skills/autowork/scripts/blindspot-inventory.sh scan --force`.

**`skills/autowork/scripts/check-latency-budgets.sh`** -- Hook latency budget benchmark + enforcement. Spawns each of the six hot-path hooks (`prompt-intent-router`, `pretool-intent-guard`, `pretool-timing`, `posttool-timing`, `stop-guard`, `stop-time-summary`) with synthetic JSON payloads, measures median + p95 over N samples (default 5), and compares against per-hook budgets. Default budgets in milliseconds: `prompt-intent-router=1200`, `pretool-intent-guard=300`, `pretool-timing=200`, `posttool-timing=200`, `stop-guard=1000`, `stop-time-summary=400`. Per-hook env override: `OMC_LATENCY_BUDGET_<UPPER_NAME>_MS=<ms>` (hyphens → underscores; `.sh` suffix dropped). Subcommands: `benchmark` and `check` (functionally identical — both exit 1 on breach; `check` is the CI-named alias signaling failure intent), `show-budgets` (table). CI runs only `tests/test-latency-budgets.sh` (framework verification with synthetic budgets); the actual `check` subcommand against real hooks is documented for pre-release manual invocation rather than gating every PR (real-hook execution is too slow + too noisy on shared CI runners). Budgets are upper bounds — typical runs land 30-60% below — so a regression measurable to the user (>50% increase) trips the gate without false-positive flapping.

**FINDINGS_JSON parser** (in `lib/state-io.sh` callers, helpers live in `common.sh`) -- Two helpers were added in v1.28.0 for the structured reviewer-finding contract: `extract_findings_json(message)` parses a single-line `FINDINGS_JSON: [...]` block from the tail of an agent message (preferring `^FINDINGS_JSON:` anchor, requires `[` to validate), strips fenced code blocks, and emits one canonical JSON row per finding via `jq -c`; `normalize_finding_object(row)` coerces severity aliases (`critical`/`p0`/`p1`/`p2`/`blocker` → `high`/`medium`/`low`), normalizes unknown categories to `other`, caps `claim` to 140 chars and `evidence`/`recommended_fix` to 600 chars each, and emits a `_finding_id` for de-duplication. `extract_discovered_findings` takes the JSON path when present and emits rows with a `.structured` field carrying the full payload, falling through to the legacy prose-heuristic path only when the JSON line is missing/empty/malformed (fail-open by design). Single-line array form is required; pretty-printed JSON is intentionally not supported. The contract-presence regression net is `tests/test-findings-json.sh`. Emitting agents: `quality-reviewer`, `excellence-reviewer`, `oracle`, `abstraction-critic`, `metis`, `design-reviewer`, `briefing-analyst`.

### Cognitive Defaults

**`quality-pack/memory/core.md`** -- Loaded into every session via CLAUDE.md. Defines thinking quality standards (reason before acting, diagnose before fixing, track progress), workflow rules (classify intent, classify domain, route to specialists, test after changes, review before stopping), code quality rules (no placeholder stubs, no restating comments), anti-patterns (forbidden behaviors like asking "should I proceed?"), and failure recovery (stop retrying after 3 failures, switch approach or delegate to oracle).

---

## Request Flow

```
User prompt
  |
  v
[UserPromptSubmit hook] prompt-intent-router.sh
  |-- Normalize prompt text (strip /ulw, ultrathink prefixes)
  |-- classify_task_intent() -> execution | continuation | advisory | checkpoint | session_management
  |-- infer_domain() -> coding | writing | research | operations | mixed | general
  |-- Reset per-turn counters (stop_guard_blocks, stall_counter, etc.)
  |-- Preserve or update current_objective based on intent
  |-- Build context_parts array:
  |     - Mode directive (execution, continuation, advisory, checkpoint, or session-mgmt)
  |     - Thinking directive (plan/reflect requirements)
  |     - Domain-specific specialist hints
  |     - Prior specialist conclusions (for continuations)
  |     - Ultrathink directive (if keyword present)
  |     - Council evaluation guidance (if broad project evaluation detected)
  |-- Inject via hookSpecificOutput.additionalContext
  |
  v
Claude processes with injected context
  |
  |-- [PreToolUse: Agent] record-pending-agent.sh
  |     Records agent dispatch to pending_agents.jsonl for compact tracking
  |
  |-- [PostToolUse: Edit/Write/MultiEdit] mark-edit.sh
  |     Records last_edit_ts, resets guard counters
  |
  |-- [PostToolUse: Bash] record-verification.sh
  |     Detects test/build/lint commands, records last_verify_ts
  |
  |-- [PostToolUse: MCP verification tools] record-verification.sh
  |     Detects Playwright/computer-use verification, records last_verify_ts
  |
  |-- [PostToolUse: Grep/Read] record-advisory-verification.sh
  |     Tracks code inspection, detects stalls (configurable threshold, default 12)
  |
  |-- [PostToolUse: Agent] reflect-after-agent.sh
  |     Injects reflection prompt, warns about premature synthesis
  |
  |-- [SubagentStop] record-subagent-summary.sh
  |     Logs agent conclusions to subagent_summaries.jsonl
  |
  |-- [SubagentStop: quality-reviewer/editor-critic/metis/briefing-analyst/excellence-reviewer/design-reviewer] record-reviewer.sh
  |     Parses VERDICT line, records last_review_ts, ticks dimension(s)
  |
  v
Claude attempts to stop
  |
  v
[Stop hook] stop-guard.sh
  |-- Check 1: Advisory over codebase without code inspection? -> Block (max 1)
  |-- Check 2: Deferral language without user-requested checkpoint? -> Block (max 2)
  |-- Check 3: Edits without review or verification (code/doc clocks)? -> Block (max 3)
  |-- Check 4: Prescribed dimensions missing on complex task? -> Block (max 3)
  |-- Check 5: 3+ files edited without excellence review? -> Block (max 1)
  |-- Check 6: Complex plan without fresh `metis` stress-test? -> Block (opt-in, max 1)
  |-- Check 7: Final wrap missing audit-ready closure? -> Block
  |-- All checks pass or caps reached -> Allow stop
  |
  v
[On compaction]
  pre-compact-snapshot.sh -> Snapshot state to precompact_snapshot.md
  post-compact-summary.sh -> Merge native summary with snapshot into compact_handoff.md
  |
  v
[On session resume or post-compact restart]
  session-start-resume-handoff.sh -> Copy state from previous session, inject context
  session-start-compact-handoff.sh -> Read snapshot, inject continuation directive
```

---

## State Management

Session state is stored at:

```
~/.claude/quality-pack/state/<SESSION_ID>/
  session_state.json           # Primary key-value state (JSON object)
  recent_prompts.jsonl         # Last 12 user prompts with timestamps
  subagent_summaries.jsonl     # Last 16 agent conclusions
  pending_agents.jsonl         # Currently in-flight agent dispatches (managed by record-pending-agent.sh / record-subagent-summary.sh)
  edited_files.log             # Paths of edited files
  classifier_telemetry.jsonl   # Per-turn classification rows + misfire annotations (capped at 100 rows)
  discovered_scope.jsonl       # Findings captured from advisory specialists (council lenses, metis, briefing-analyst); capped at 200 rows
  exemplifying_scope.json      # Checklist of sibling scope items for example-marker prompts; managed by record-scope-checklist.sh and enforced by stop-guard
  findings.json                # Council Phase 8 master finding list (model-managed via record-finding-list.sh); waves[] declares the active wave plan
  gate_events.jsonl            # Per-event outcome attribution rows (gate fires + finding-status changes); capped at OMC_GATE_EVENTS_PER_SESSION_MAX, default 500. Added v1.14.0.
  design_contract.md           # Inline 9-section Design Contract captured from frontend-developer / ios-ui-developer SubagentStop, with agent/ts/cwd frontmatter. Read by design-reviewer / visual-craft-lens via find-design-contract.sh when no project-root DESIGN.md exists. Latest emission wins (the user may iterate). Added post-v1.15.0.
  precompact_snapshot.md       # Snapshot created before compaction
  compact_handoff.md           # Combined handoff document
  internal_edits.log           # Edits to internal Claude paths (excluded from tracking)
  rate_limit_status.json       # Rate-limit windows pre-staged by statusline.py: {five_hour, seven_day}.{used_percentage, resets_at_ts}. Pro/Max sessions only; absent on raw API-key sessions. Read by stop-failure-handler.sh on StopFailure.
  resume_request.json          # Written by stop-failure-handler.sh when Claude Code emits StopFailure: {rate_limited, matcher, original_objective, last_user_prompt, resets_at_ts, project_key, rate_limit_snapshot, resumed_at_ts, dismissed_at_ts, resume_attempts, last_attempt_ts, last_attempt_outcome, last_attempt_pid, ...}. project_key (added Wave 1) is the git-remote-first / cwd-hash _omc_project_key for the cwd at write time — used by Wave 1's resume-hint hook to match worktrees and clone-anywhere paths. Wave 2 `/ulw-resume` claim flow stamps resumed_at_ts (or dismissed_at_ts via --dismiss). Wave 3 watchdog stamps last_attempt_* on each launch attempt and increments resume_attempts. **Chain-depth cap (formula `origin_chain_depth + resume_attempts >= 3`)**: `claim-resume-request.sh --watchdog-launch` refuses to launch when the cumulative depth reaches 3. `session-start-resume-handoff.sh` propagates `origin_session_id` (the first session in the chain) and `origin_chain_depth` (incremented per resume) from the source artifact into the resumed session's state; `stop-failure-handler.sh` stamps both fields onto every new `resume_request.json` so the cap accumulates across the chain. Without this propagation, a watchdog-launched session that itself rate-limits would write a fresh artifact with `resume_attempts: 0` and the cap would silently reset — the chain could then run forever. Read by session-start-resume-hint.sh (Wave 1 hint), claim-resume-request.sh (Wave 2 atomic claim), and resume-watchdog.sh (Wave 3 daemon).
  resume_hint.md               # Markdown sidecar written by session-start-resume-hint.sh on emit (Wave 1). Frontmatter: origin_session_id, artifact_path, match_scope, matcher, emitted_at_ts, source. Body: the rendered additionalContext that was injected. Provides /ulw-status visibility and a paper trail the future Wave 3 watchdog can inspect without re-deriving from gate events.
  timing.jsonl                 # Per-call timing rows appended by pretool-timing.sh / posttool-timing.sh / prompt-intent-router.sh / stop-time-summary.sh (lock-free, sub-PIPE_BUF O_APPEND). Row shapes (discriminated by `kind`): {kind:"prompt_start", ts, prompt_seq}, {kind:"prompt_end", ts, prompt_seq, duration_s}, {kind:"start", ts, tool, prompt_seq, tool_use_id?, subagent?}, {kind:"end", ts, tool, prompt_seq, tool_use_id?}, {kind:"directive_emitted", ts, prompt_seq, name, chars} (per-directive size in locale-aware codepoint count — emitted by prompt-intent-router.sh's add_directive helper for /ulw-report and offline cost-attribution analysis; field is `chars` not `bytes` because `${#var}` in bash is locale-aware and returns codepoints under UTF-8, which correlates with token cost better than raw bytes anyway). Read by stop-time-summary.sh's `timing_aggregate` for the Stop epilogue, by show-time.sh for /ulw-time, and by /ulw-status. Fast-path-skipped when `time_tracking=off`. Aggregator silently ignores unknown kinds via the reduce `else .` branch — directive_emitted rows do not perturb start/end pairing.
```

Cross-session ledgers (in `~/.claude/quality-pack/`, not per-session):

```
session_summary.jsonl          # One summary row per TTL-swept session (cap: 500/400)
classifier_misfires.jsonl      # Aggregated misfire rows tagged with session id (cap: 1000/800)
serendipity-log.jsonl          # Serendipity Rule applications across sessions (cap: 2000/1500)
gate-skips.jsonl               # /ulw-skip honored events for threshold tuning (cap: 200/150)
gate_events.jsonl              # Per-event outcome rows aggregated from per-session gate_events.jsonl (cap: 10000/8000). Added v1.14.0.
used-archetypes.jsonl          # Cross-session archetype priors keyed by `_omc_project_key` (git-remote-first, cwd fallback); written by record-archetype.sh on UI-specialist SubagentStop, read by `recent_archetypes_for_project` to feed the router's anti-anchoring advisory (cap: 500/400). Added post-v1.15.0.
timing.jsonl                   # Cross-session per-session-summary rollup written by stop-time-summary.sh via `timing_record_session_summary` (dedups by session at write time — multi-Stop sessions don't accrue inflated totals). Row shape: {ts, session_id, project_key} (v1.31.0 Wave 4 renamed `session` → `session_id`; pre-Wave-4 rows coexist via backwards-compat dedup) merged with the `timing_aggregate` output (walltime_s, agent_total_s, agent_breakdown, agent_calls, tool_total_s, tool_breakdown, tool_calls, idle_model_s, concurrent_overhead_s, prompt_count, prompts_seq, active_pending, orphan_end_count). v1.34.1 added `concurrent_overhead_s`: positive when parallel agent/tool work outran walltime (`agent + tool > walltime`); used by show-time.sh / timing_format_full to re-normalize the bar against work-time and disclose "parallelism saved ~Xm" — without this, the bar percentages can sum to >100% of walltime, which historically rendered as broken-looking math. Sessions with walltime <5s are skipped (noise floor). Read by show-time.sh week/month/all rollups and the `/ulw-report` "Time spent across sessions" section. Cap: 10000 rows, pruned on the regular state-TTL sweep with `time_tracking_xs_retain_days` horizon. Added v1.24.0.
defect-patterns.json           # Historical defect-category counters
agent-metrics.json             # Invocations / clean / findings per agent type
```

All seven JSONL caps go through `_cap_cross_session_jsonl` in `common.sh`; the format `cap/retain` shows the trigger threshold and post-truncation tail size.

`session_summary.jsonl` row schema (canonical writer: `sweep_stale_sessions` in `common.sh`):

| Field | Type | Source |
|---|---|---|
| `session_id` | string | session directory name |
| `start_ts`, `end_ts` | string (epoch) | `session_state.json` |
| `domain`, `intent` | string | classifier output stored in state |
| `edit_count`, `code_edits`, `doc_edits` | int | `edited_files.log` + state counters |
| `verified`, `verify_outcome`, `verify_confidence` | bool / string / int | `record-verification.sh` writes |
| `reviewed`, `dispatches` | bool / int | `record-reviewer.sh` and dispatch counter |
| `guard_blocks`, `dim_blocks`, `exhausted` | int / int / bool | `stop-guard.sh` counters |
| `outcome` | enum | `completed` (all gates satisfied) \| `released` (clean exit, no gates fired — advisory pass / no-edits) \| `skip-released` (user invoked `/ulw-skip` to bypass; gates fired but were NOT model-resolved — DO NOT count as caught) \| `exhausted` (guard cap hit) \| `abandoned` (TTL-swept without a stop) |
| `skip_count` | int | `record_gate_skip` (added v1.13.0) |
| `serendipity_count` | int | `record-serendipity.sh` (added v1.13.0) |
| `findings` | object \| null | rolled up from per-session `findings.json` at sweep time (added v1.13.0): `{total, shipped, deferred, rejected, in_progress, pending}` |
| `waves` | object \| null | rolled up from per-session `findings.json` at sweep time (added v1.13.0): `{total, completed}` |

### Install-time artifacts

Separate from session state, `install.sh` writes four install-time artifacts that persist across sessions and feed the statusline's stale-install indicator:

| Path | Purpose |
|---|---|
| `~/.claude/oh-my-claude.conf` → `repo_path` | Absolute path of the source repo `install.sh` was run from; read by the statusline to compare bundle vs. repo `VERSION`. |
| `~/.claude/oh-my-claude.conf` → `installed_version` | First line of `VERSION` at install time. Compared against `${repo_path}/VERSION` to detect tag-ahead drift. |
| `~/.claude/oh-my-claude.conf` → `installed_sha` | Full 40-char `git rev-parse HEAD` of the source repo at install time. Compared against HEAD via `git rev-list --count installed_sha..HEAD` to detect commits-ahead drift when VERSION matches. Omitted entirely (key removed from conf) when the install source is not a git worktree. |
| `~/.claude/quality-pack/state/installed-manifest.txt` | Sorted (LC_ALL=C) relative-path list of every file in the bundle at install time. Compared against the new bundle on the next install via `comm -23` to detect orphan files (present in prior release, removed from current bundle). `rsync -a` does not remove them — the warning tells the user to clean up manually. |
| `~/.claude/.install-stamp` | Empty file `touch`ed on every install. Reliable reference for "what changed since the last install" — e.g. `find ~/.claude -newer ~/.claude/.install-stamp -type f` (subject to 1-second filesystem mtime granularity). |

### State keys in `session_state.json`

| Key | Purpose |
|---|---|
| `current_objective` | Normalized task description, preserved across advisory/continuation prompts |
| `done_contract_primary` | Prompt-time statement of the primary deliverable ULW believes it is trying to finish. Usually mirrors `current_objective`, but stored separately so `/ulw-status`, compact snapshots, and resume handoff can refer to the user's original "done means this" contract explicitly. |
| `done_contract_commit_mode` | **Commit-specific** expectation derived from the latest execution prompt: `required`, `if_needed`, `forbidden`, or `unspecified`. Read by `/ulw-status`, compact/resume handoff, `stop-guard.sh` (required-commit enforcement), and `pretool-intent-guard.sh` (blocks `git commit` when forbidden). Required commits are checked against `done_contract_updated_ts`, so a commit from an earlier prompt in the same session cannot satisfy a fresh "commit this" instruction. v1.34.0 (Bug C) tightened the forbidden detection from "any publishing verb" to "commit-specific negation only" so a compound directive like "commit X. don't push Y." correctly classifies the commit as required while routing the push half through `done_contract_push_mode`. |
| `done_contract_push_mode` | **Push/publish-specific** expectation (v1.34.0). Same `required` / `if_needed` / `forbidden` / `unspecified` shape as `done_contract_commit_mode`, but specifically governs `push`, `tag`, `publish`, `release`, `ship` verbs. Read by `/ulw-status`, compact/resume handoff, `stop-guard.sh` (requires a fresh recorded publish action when `required`), and `pretool-intent-guard.sh` (blocks `git push`, `git tag`, and `gh pr/release/issue create-class` ops when `forbidden`). Allows the user to authorize a commit while forbidding the push, which the pre-v1.34.0 single-mode classifier could not distinguish. |
| `done_contract_prompt_surfaces` | Comma-separated explicit adjacent deliverables inferred from the prompt (`tests`, `docs`, `config`, `release`, `migration`). This is the early contract, not the touched-file ledger: it says what the user explicitly asked to be part of "done". |
| `done_contract_test_expectation` | Test-specific contract derived at prompt time: empty, `verify`, or `add_or_update_tests`. `verify` is the default coding-work proof bar; `add_or_update_tests` is the stronger prompt-explicit bar used when the user asked for regression coverage or test additions. |
| `verification_contract_required` | Comma-separated proof obligations derived from the prompt (`code_review`, `code_verify`, `prose_review`, `design_review`, `test_surface`, `config_surface`, `release_surface`, `migration_surface`, `commit_record`, `publish_record`). Surfaced in `/ulw-status` and compact/resume handoff so the user can see the proof plan before Stop. |
| `done_contract_updated_ts` | Epoch timestamp when the current delivery contract was last refreshed from a fresh execution prompt. Continuation/advisory prompts preserve the prior contract. |
| `last_delivery_action_ts` | Epoch timestamp of the most recent recorded commit or publish-class delivery action. Convenience summary for status/debug surfaces. |
| `last_commit_action_ts` / `last_commit_action_cmd` / `commit_action_count` | Delivery-action record written by `record-delivery-action.sh` after successful `git commit` commands. Used with `done_contract_updated_ts` by the Stop delivery-contract gate. |
| `last_publish_action_ts` / `last_publish_action_cmd` / `publish_action_count` | Delivery-action record written by `record-delivery-action.sh` after successful publish-class commands (`git push`, `git tag`, `gh pr/release/issue ...`). Used with `done_contract_updated_ts` by the Stop delivery-contract gate. |
| `inferred_contract_surfaces` | **Delivery Contract v2 (v1.34.0).** Comma-separated adjacent surfaces *inferred from the actual edits* this session (not just from prompt wording). Tokens: `tests`, `changelog`, `parser_lockstep`, `config_table_lockstep`, `docs`. Folds into `delivery_contract_blocking_items` so stop-guard catches "code edited but no test", "VERSION bumped without CHANGELOG", "conf flag added without parser site touched", "conf flag added without omc-config table touched", "migration without release notes", "≥4 code files edited but no docs". Refreshed lazily by mark-edit (on each new unique path) and by stop-guard (right before reading blockers), with the entire read-derive-write window held under `with_state_lock` for atomicity. Gated by `OMC_INFERRED_CONTRACT` (default `on`). |
| `inferred_contract_rules` | **Delivery Contract v2 (v1.34.0).** Comma-separated IDs of the inference rules currently firing: `R1_missing_tests` (≥2 code files edited, no test edited, no fresh passing high-confidence verification AFTER last code edit), `R2_version_no_changelog` (VERSION touched without CHANGELOG/RELEASE_NOTES), `R3a_conf_no_parser` (`oh-my-claude.conf.example` edited without `common.sh` `_parse_conf_file` touched), `R3b_conf_no_config_table` (`oh-my-claude.conf.example` edited without `omc-config.sh` `emit_known_flags` touched), `R4_migration_no_release` (migration file edited without changelog), `R5_code_no_docs` (≥4 code files edited but no README/docs/ touched). Used by `inferred_contract_blocker_messages` to render audit-ready blocker lines including a sample of the offending file paths. R3a + R3b together enforce the three-site conf-flag triple-write rule from CLAUDE.md "Coordination Rules". |
| `inferred_contract_ts` | **Delivery Contract v2 (v1.34.0).** Epoch timestamp of the last `refresh_inferred_contract` call. Updated only when a NEW unique path is appended in mark-edit (or when stop-guard refreshes immediately before the gate decision). |
| `task_domain` | Classified domain: coding, writing, research, operations, mixed, general |
| `task_intent` | Classified intent: execution, continuation, advisory, checkpoint, session_management |
| `workflow_mode` | Active mode (currently: `ultrawork` or empty) |
| `last_edit_ts` | Epoch timestamp of the last file edit (any type — backward compat) |
| `last_code_edit_ts` | Epoch timestamp of the last code edit (non-doc path) |
| `last_doc_edit_ts` | Epoch timestamp of the last doc edit (matched by `is_doc_path`) |
| `code_edit_count` | Cached count of unique code files edited this session |
| `doc_edit_count` | Cached count of unique doc files edited this session |
| `last_verify_ts` | Epoch timestamp of the last test/build/lint verification |
| `last_verify_cmd` | The verification command that was run |
| `last_verify_confidence` | Integer 0-100 score of the last verification (lint-only ≈ 30, framework runs ≈ 50+, project test suites ≈ 70+); compared against `OMC_VERIFY_CONFIDENCE_THRESHOLD` by stop-guard |
| `last_verify_factors` | Pipe-delimited per-factor breakdown of the last Bash-path verification score, in the format `test_match:N\|framework:N\|output_counts:N\|clear_outcome:N\|total:N`. The trailing `total` matches `last_verify_confidence`. Backed by `score_verification_confidence_factors` in `lib/verification.sh`; surfaced by `/ulw-status` for debug visibility (added in v1.27.0 F-023). MCP-path verifications do not yet write this key — `/ulw-status` shows `(MCP-path verification — per-factor breakdown not yet recorded)` in that case. |
| `last_verify_method` | Classification of the last verification signal. Bash-command checks resolve to one of `project_test_command`, `framework_keyword`, `output_signal`, or `builtin_verification` (see `detect_verification_method` in `common.sh`). MCP observations resolve to `mcp_<check_type>` (e.g. `mcp_browser_visual_check`, `mcp_browser_console_check`). |
| `last_review_ts` | Epoch timestamp of the last reviewer agent completion (any code-side reviewer) |
| `last_doc_review_ts` | Epoch timestamp of the last editor-critic (prose) completion |
| `last_advisory_verify_ts` | Epoch timestamp of the last code inspection during advisory tasks |
| `last_assistant_message` | Claude's last response (captured at stop hook entry) |
| `last_assistant_message_ts` | Epoch timestamp of the above |
| `last_user_prompt` | Raw text of the last user prompt |
| `last_user_prompt_ts` | Epoch timestamp of the above |
| `prompt_seq` | Monotonic per-prompt epoch counter (added v1.24.0). Incremented by `prompt-intent-router.sh` on every UserPromptSubmit. Tagged onto each timing.jsonl row so `timing_aggregate` only pairs same-epoch start/end rows — pre-compaction starts cannot bind to post-compaction ends. Surfaced via `timing_next_prompt_seq` / `timing_current_prompt_seq` / `timing_latest_finalized_prompt_seq` helpers in `lib/timing.sh`. |
| `last_meta_request` | Normalized text of the last advisory/session-mgmt/checkpoint prompt |
| `last_verify_outcome` | Result of the last verification: `passed` or `failed` |
| `last_excellence_review_ts` | Epoch timestamp of the last excellence-reviewer completion |
| `review_had_findings` | Whether the last review reported actionable findings (`true`/`false`) |
| `dim_bug_hunt_ts` | Epoch when `bug_hunt` dimension was last ticked |
| `dim_code_quality_ts` | Epoch when `code_quality` dimension was last ticked |
| `dim_stress_test_ts` | Epoch when `stress_test` dimension was last ticked |
| `dim_prose_ts` | Epoch when `prose` dimension was last ticked |
| `dim_completeness_ts` | Epoch when `completeness` dimension was last ticked |
| `dim_traceability_ts` | Epoch when `traceability` dimension was last ticked |
| `dim_design_quality_ts` | Epoch when `design_quality` dimension was last ticked |
| `ui_edit_count` | Number of unique UI files (`.tsx`, `.jsx`, `.vue`, `.css`, etc.) edited — subset of `code_edit_count` |
| `ui_platform` | Platform classification of the most recent UI prompt (`web` / `ios` / `macos` / `cli` / `unknown`); written by `prompt-intent-router.sh` when a UI request fires the design hint, consumed by `record-subagent-summary.sh` to attribute archetype rows correctly. |
| `ui_intent` | UI-intent classification of the most recent UI prompt (`build` / `style` / `polish` / `fix` / `none`); written alongside `ui_platform`. |
| `ui_domain` | Product-domain classification of the most recent UI prompt (`fintech` / `wellness` / `creative` / `devtool` / `editorial` / `education` / `enterprise` / `consumer` / `unknown`); written alongside `ui_platform`. |
| `stop_guard_blocks` | Number of times the review/verify gate has blocked (cap: 3) |
| `dimension_guard_blocks` | Number of times the dimension gate has blocked (cap: 3) |
| `dimension_resume_grace_used` | Whether the one-shot resumed-session dimension-gate grace has been used (`1` or empty) |
| `session_handoff_blocks` | Number of times the deferral gate has blocked (cap: 2) |
| `advisory_guard_blocks` | Number of times the advisory inspection gate has blocked (cap: 1) |
| `pretool_intent_blocks` | Number of times the `pretool-intent-guard.sh` PreToolUse hook denied a destructive git/gh command because `task_intent` was `advisory`, `session_management`, or `checkpoint` (counter, no cap) |
| `discovered_scope_blocks` | Number of times the discovered-scope gate has blocked a stop because pending findings from advisory specialists were not addressed (cap: 2 by default; raised to `wave_total + 1` when a council Phase 8 wave plan is active in `findings.json` AND the plan is NOT under-segmented per `is_wave_plan_under_segmented` — narrow plans stay at cap=2 to avoid the polarity bug where 5×1-finding plans would otherwise release after 5 narrow waves). Reset by `/ulw-skip`. |
| `exemplifying_scope_required` | `1` when the latest execution prompt used example markers AND classified as execution intent — the **narrow** trigger that arms the blocking scope-checklist gate. Cleared on the next fresh non-exemplifying execution prompt. (v1.26.0 broadened the **directive** trigger to also fire on completeness vocabulary and on advisory + continuation intents — but the **blocking gate** stays gated to this narrow trigger so blocking-on-advisory is avoided. The two are decoupled in `prompt-intent-router.sh` via the bash variables `COMPLETENESS_DIRECTIVE_FIRES` (broader, drives directive emission) and `EXEMPLIFYING_SCOPE_DETECTED` (narrow, drives this state key).) |
| `exemplifying_scope_prompt_ts` | Epoch timestamp of the prompt that armed the exemplifying-scope checklist requirement; `exemplifying_scope.json.source_prompt_ts` must match this to count as current. |
| `exemplifying_scope_prompt_preview` | Truncated prompt preview used by `record-scope-checklist.sh` when creating `exemplifying_scope.json`. |
| `exemplifying_scope_checklist_ts` | Epoch timestamp when `record-scope-checklist.sh init` last recorded a checklist for the current example-marker prompt. |
| `exemplifying_scope_pending_count` | Cached pending-item count from `exemplifying_scope.json`; updated by `record-scope-checklist.sh status`. |
| `exemplifying_scope_satisfied_ts` | Epoch timestamp when the exemplifying-scope checklist reached zero pending items. |
| `exemplifying_scope_blocks` | Number of times the exemplifying-scope gate has blocked Stop because the checklist was missing/stale or still had pending items (cap: 2 unless `guard_exhaustion_mode=block`). |
| `wave_shape_blocks` | Number of times the wave-shape gate (v1.22.0) has blocked a stop because the active wave plan is under-segmented (avg <3 findings/wave on a master list of ≥5 findings AND ≥2 waves). Cap: 1 per wave plan. Reset by `record-finding-list.sh init` so a fresh plan gets a fresh gate budget. The numerics live in three places: this predicate, the gate's user-facing block reason in `stop-guard.sh`, and the canonical text in `bundle/dot-claude/skills/council/SKILL.md` Step 8. |
| `serendipity_count` | Number of times `record-serendipity.sh` has logged a Serendipity Rule application this session. Surfaced in `/ulw-status` full mode. |
| `last_serendipity_ts` | Epoch of the most recent Serendipity Rule application, written by `record-serendipity.sh`. |
| `last_serendipity_fix` | Short description of the most recent Serendipity Rule application — appended to the `Serendipity fires:` row in `/ulw-status`. |
| `excellence_guard_triggered` | Whether the excellence gate has already fired this session (`1` or empty) |
| `memory_drift_hint_emitted` | `1` after `prompt-intent-router.sh` injects the v1.20.0 memory-drift hint at session start; one-shot per session — second and later prompts do NOT re-emit |
| `drift_warning_emitted` | `1` after `canary-claim-audit.sh` (v1.26.0 Wave 2) emits the silent-confab soft alert at Stop. One-shot for the lifetime of the session_state.json file — the canary keeps recording per-event audit rows in `<session>/canary.jsonl` after the alert fires, but the user-facing systemMessage is suppressed for the rest of the session to avoid alarm fatigue. Resets implicitly when a fresh session gets a new state file (no explicit clear path). Mirrors the `memory_drift_hint_emitted` lifetime. |
| `guard_exhausted` | Epoch timestamp when guard caps were reached and stop was allowed |
| `guard_exhausted_detail` | Diagnostic string showing which gates were still unsatisfied at exhaustion |
| `session_outcome` | How the session ended. v1.34.2 expanded the enum to 5 values: `completed` (all gates satisfied — strongest positive signal), `released` (clean exit without firing any gates — advisory pass / no-edits / first-prompt release), `skip-released` (user explicitly invoked `/ulw-skip` to bypass; gates fired but were NOT model-resolved — downstream trust surfaces MUST exclude these from "caught + resolved" claims), `exhausted` (guard caps reached after N blocks; gates fired and remained unsatisfied), `abandoned` (TTL-swept without a stop — model crashed mid-turn). Carried into `session_summary.jsonl` for cross-session analytics. |
| `session_start_ts` | Epoch timestamp of the first ULW activation in the session; enables session-duration reporting in `/ulw-status` |
| `project_key` | First-write-wins. Result of `_omc_project_key()` (git-remote-first, cwd-hash fallback) at first ULW activation. Read by the natural sweep in `_sweep_append_*` to tag cross-session telemetry rows (`gate_events.jsonl`, `session_summary.jsonl`, `serendipity-log.jsonl`, `classifier_telemetry.jsonl`, `used-archetypes.jsonl`) for multi-project `/ulw-report` slicing. v1.31.0 Wave 4 wired the read path; v1.32.6 finally wired the write path in `prompt-intent-router.sh` after the gap was surfaced by the v1.32.5 reviewer pass. Stable across prompts in the same session — git remote URL changes mid-session do NOT update the recorded value. |
| `cwd` | First-write-wins. Working directory captured at first ULW activation from the hook JSON's `.cwd`. Used by `discover_latest_session` (which command-line scripts without hook JSON rely on) to prefer the session whose cwd matches the current process — prevents cross-project session leak when two sessions race on touch. Stable across prompts in the same session. |
| `subagent_dispatch_count` | Count of Agent tool calls dispatched this session (each `PreToolUse: Agent` increments it); surfaced in `/ulw-status` for cost visibility |
| `gate_skip_ts` | Epoch timestamp when `/ulw-skip` was last invoked (set by `ulw-skip-register.sh`) |
| `gate_skip_reason` | Free-text reason captured at `/ulw-skip` registration time; surfaced in `/ulw-status`. v1.38.0 made this lockstep with the `ulw-skip:registered` gate-event row (`details.reason`) so the reason exists in BOTH the per-session state and the cross-session ledger. |
| `gate_skip_edit_ts` | Edit clock captured at `/ulw-skip` registration time; stop-guard invalidates the skip if `last_edit_ts` has advanced past this value |
| `whats_new_emitted` | Per-session dedupe flag (`1` after first emit) for the SessionStart `whats-new` hook. Cross-session dedupe lives at `~/.claude/quality-pack/.last_session_seen_version`. v1.38.0. |
| `stall_counter` | Consecutive Read/Grep calls without a progress action |
| `resume_source_session_id` | Session ID of the session this one was resumed from |
| `last_compact_trigger` | What triggered the last compaction |
| `last_compact_request_ts` | When the last compaction was requested |
| `last_compact_rehydrate_ts` | When the post-compact SessionStart hook last read the handoff |
| `last_compact_summary` | Native compact summary captured from `PostCompact` |
| `last_compact_summary_ts` | When the native compact summary was captured |
| `just_compacted` | `1` if a PostCompact just fired and the next `UserPromptSubmit` should bias toward continuation; single-use, cleared on first read |
| `just_compacted_ts` | Epoch when `just_compacted` was set; 15-minute staleness window |
| `review_pending_at_compact` | `1` if a quality review was pending when the last compact fired; drives the "MUST run quality-reviewer" directive in the compact-resume injection |
| `compact_race_count` | Number of back-to-back compactions where the prior snapshot had not yet been consumed (diagnostic telemetry) |

---

## Compaction Continuity

When Claude Code compacts a session — either automatically when the context budget is approaching the limit, or manually via `/compact` — the harness runs three hooks to preserve working state:

1. **`PreCompact`** → `pre-compact-snapshot.sh`: writes `precompact_snapshot.md` with objective, domain, intent, delivery contract, last assistant message, recent prompts, active plan, edited files, review/verify status, remaining obligations, pending specialists, and a `review_pending_at_compact` flag. Back-to-back compactions archive an unconsumed prior snapshot as `precompact_snapshot.<mtime>.md` (retained up to 5 files).

2. **`PostCompact`** → `post-compact-summary.sh`: reads Claude Code's `.compact_summary` field (or emits a fallback when empty), combines it with the snapshot into `compact_handoff.md`, and sets a `just_compacted` flag so the next `UserPromptSubmit` can bias classification toward continuation. `HOOK_DEBUG=true` dumps the raw hook JSON to `compact_debug.log` for schema diagnosis.

3. **`SessionStart` (source=compact)** → `session-start-compact-handoff.sh`: injects the handoff document via `additionalContext`, with a directive stack that re-asserts ultrawork mode, carries forward the preserved delivery contract, lists any in-flight specialist dispatches for re-dispatch, names remaining obligations, and enforces pending-review requirements.

Pending specialist tracking uses a new `PreToolUse` hook (`record-pending-agent.sh`) matched on the `Agent` tool. Every dispatch appends to `pending_agents.jsonl`; every `SubagentStop` removes the FIFO-oldest entry matching the `subagent_type`. This is a per-type counter — same-type concurrent dispatches cannot be distinguished, but the count remains accurate.

On `/ulw-off`, `ulw-deactivate.sh` clears the compact-continuity flags and deletes `pending_agents.jsonl` so stale state from a deactivated session cannot bleed into a later compact resume.

---

## Intent Classification Order

The classification order in `classify_task_intent()` is a protected design decision. Changing it affects routing accuracy across all prompts. The order:

1. **Continuation** (`is_continuation_request`) -- "continue", "resume", "carry on", "keep going", "pick it back up". Matched first because continuation prompts often contain advisory-like words ("continue where you left off?") that would otherwise misclassify.

2. **Checkpoint** (`is_checkpoint_request`) -- "checkpoint", "pause here", "stop here", "for now", "wave 1 only", "first phase only". Explicit user requests for phased delivery.

3. **Session management** (`is_session_management_request`) -- Questions about session strategy: "should I start a new session?", "is the context budget okay?". Requires both session-related keywords AND question-form syntax.

4. **Imperative** (`is_imperative_request`) -- Polite commands: "can you fix...", "please implement...", "go ahead and...", "I need you to...". Checked BEFORE advisory because "can you fix the bug?" is an action request, not advice-seeking. The verb list covers ~40 common action verbs. Two additional branches catch natural-English imperative shapes the head-anchored patterns miss: **tail-position imperative** (a prompt that opens advisory but closes with a destructive verb after a sentence boundary — `Review the plan. Then commit the changes.`) and **implementation-verb-led conjunction** (v1.23.0; `Implement and then commit as needed`, `Build it, then push to origin`, `Refactor X and tag v2.0` — impl-verb head + (and|,) conjunction + destructive verb + object-marker tail).

5. **Advisory** (`is_advisory_request`) -- Questions and opinion-seeking: "should we...", "what do you think...", "is it better to...", "pros and cons". Only matched if none of the above patterns triggered first.

6. **Default: execution** -- If nothing else matches, the prompt is treated as a direct execution request.

**Defense-in-depth: prompt-text trust override (v1.23.0)** -- If the classifier mis-routes despite the widened patterns, `pretool-intent-guard.sh` re-reads `recent_prompts.jsonl` and re-runs `is_imperative_request` against the most recent user prompt before blocking a destructive op. When EVERY destructive non-allowed segment in the attempted command has its verb authorized in the prompt with an imperative-tail object marker (or at end-of-prompt), the guard allows and records `gate=pretool-intent` `event=prompt_text_override` for audit. Compound-command safety: `git commit && git push --force` only passes when both `commit` and `push` are authorized in the prompt — not just the first one. Conf-gated by `prompt_text_override` (default `on`).

**Bias-defense directive layer (router-side)** -- The prompt-intent-router emits up to three directives on fresh-execution prompts to defend against classifier-blind biases (the classifier got the intent right but the *prompt shape* hides a bias):

- `prometheus_suggest` (default off; declare-and-proceed since v1.24.0) — defends against over-commitment when an execution prompt is short, product-shaped, and unanchored. The directive tells the model to state its scope interpretation in one or two declarative sentences as part of its opener and proceed; the user can redirect in real time. The flag does NOT instruct a hold.
- `intent_verify_directive` (default off, suppressed when prometheus already fired; declare-and-proceed since v1.24.0) — defends against over-commitment when an execution prompt is short and unanchored. The directive tells the model to state its interpretation of the goal in one declarative sentence as part of its opener and start work; the user can redirect in real time. Pause case is narrow: only when confidence is low AND the wrong call would be hard to reverse. The flag does NOT instruct a hold.
- `exemplifying_directive` (default on, v1.23.0) — defends against under-commitment when the prompt uses example markers (`for instance`, `e.g.`, `such as`, etc.) by instructing the model to treat the example as one item from an enumerable class. Symmetric to (but opposite of) the other two; fires INDEPENDENTLY because narrowing and widening are orthogonal.
- `exemplifying_scope_gate` (default on) — hardens `exemplifying_directive` by requiring `exemplifying_scope.json` before Stop. The model records sibling items via `record-scope-checklist.sh init`; each item must become `shipped` or `declined` with a concrete WHY. This closes the gap where the directive could be ignored and the literal example still shipped alone.

The three directives emit `gate=bias-defense` `event=directive_fired` rows for `/ulw-report` audit. The hard exemplifying-scope gate emits `gate=exemplifying-scope` block/exhausted rows. The mark-deferred validator emits `gate=mark-deferred` `event=strict-bypass` rows when `OMC_MARK_DEFERRED_STRICT=off` lets a would-be-rejected reason slip through (audit row carries the truncated reason under `.details.reason`); `/ulw-report` aggregates these into the "Mark-deferred strict-bypasses" section so silent-skip patterns remain visible across sessions.

---

## Domain Scoring

`infer_domain()` scores the prompt text against four keyword lists using case-insensitive grep:

- **Coding**: ~35 keywords (bug, fix, refactor, implement, component, endpoint, API, schema, deploy, docker, etc.)
- **Writing**: ~20 keywords (draft, essay, article, report, proposal, email, manuscript, cover letter, etc.)
- **Research**: ~20 keywords (research, investigate, analyze, compare, benchmark, audit, evaluate, etc.)
- **Operations**: ~15 keywords (plan, roadmap, timeline, agenda, meeting, follow-up, checklist, prioritize, etc.)

Each domain gets a score equal to the number of keyword matches. The domain with the highest score wins. If all scores are zero, the domain defaults to `general`.

**Mixed domain**: Triggered when coding has a nonzero score and a second domain scores at least 40% of the primary domain's score. This captures prompts like "research the API options and implement the best one" where both research and coding are significant.

---

## Paradigm choices and alternatives considered

This section is the "why this shape, not another" companion to the "what" above. Read it before contemplating a paradigm shift — the alternatives were enumerated in v1.32.x via a `divergent-framer` pass (the post-v1.31.3 advisory item 10, deferred until items 1-9 stabilized) and the conclusion was **no shift**, with explicit redirect-if conditions named below.

### The current paradigm (Framing 1 — chosen)

**Prompt-injected directive substrate.** The harness is transparent middleware: `prompt-intent-router.sh` classifies the user's prompt and reshapes the model's context window with text directives (`EXEMPLIFYING SCOPE DETECTED`, `INTENT-BROADENING DIRECTIVE`, `DIVERGENT-FRAMING DIRECTIVE`, `EXHAUSTIVE AUTHORIZATION DETECTED`, etc.). `stop-guard.sh` enforces completion via Stop-hook gates with tiered caps (3 review/verification, 2 session-handoff and discovered-scope, 1 advisory and excellence). State is per-session JSON; cross-session aggregates are JSONL. Specialists are `.md` agent files with `disallowedTools` boundaries. Skills are thin `SKILL.md` wrappers.

**Why it wins for the current scope.** The constraints — solo-dev cognitive overhead, substrate stability (bash + jq is preinstalled everywhere), Anthropic relationship (the harness rides published Claude Code hook surfaces, never forks), forward velocity (16 v1.32.x releases in one week of autonomous-loop sessions), adversarial robustness (recent 4-attacker security review closed via local-file primitives + `disallowedTools`) — all favor the status quo. The trade-off the paradigm makes is sophistication for installability; that trade is correct as long as the project stays solo-dev or single-team and Claude-Code-only.

### Alternatives considered and rejected (for now)

| Framing | Mental model | Why rejected for current scope |
|---|---|---|
| **MCP-first capability substrate** | Quality gates / classifiers / memory exposed as typed MCP tools the model calls explicitly. | Install friction (Node/Python server with auth + transport + lifecycle); Claude-Code-side gate semantics become "the model has to *choose* to call them" — exactly the loop the prompt-injection paradigm was built to remove. |
| **Output-style + slash-command shell** | Native Claude Code config bundle only. No hooks, no state, no classifier. | Cannot enforce — only suggest. The 3-block stop cap, FINDINGS_JSON parsing, and per-session counters that drive measurable outcomes do not exist. The harness's differentiator is enforcement; this paradigm gives that up. |
| **Telemetry-first, intervention-second** | Observability primary; directives derived from measured outcomes. | Telemetry surface is itself an attack target; feedback loop is statistically slow (n=many sessions per directive); without baseline-comparison framework, telemetry is bookkeeping cost without decision yield (see the v1.32.4 router cost audit Phase 2-4 deferrals — the canonical evidence). |
| **Sub-agent orchestrator (graph-of-roles)** | Main thread navigates a state machine; every prompt routes through a planner→researcher→implementer→reviewer graph. | Latency / cost balloon (every node is a model call); breaks the user's "ULW = momentum" expectation on small tasks; per-session JSON paradigm doesn't survive (graph state needs a workflow engine). |

### Redirect-if conditions

The current paradigm is correct *for the current scope*; it is not correct *forever*. Revisit the rank when **either** of these holds:

- **Distribution shift.** The harness ships to ≥10 external users. Install-friction cost is now amortized across users instead of paid by one solo dev; typed contracts (MCP) become non-negotiable for support overhead reasons.
- **Surface shift.** The harness needs to run inside non-Claude-Code IDEs (Cursor, Windsurf, Zed). Cross-IDE portability is non-negotiable; MCP becomes the only credible substrate.

When either trips, dispatch `divergent-framer` again with the updated constraints and re-rank. **Framing 2 (MCP-first) is the most likely successor.**

### Within-paradigm improvement vectors (surfaced by the framer's "Makes hard" rows)

These are not paradigm shifts but real costs of the current paradigm worth chipping at as polish work:

- **Directive wording drift.** Behavior is text-coupled; tiny edits to directive text silently change outcomes. The router cost audit (Phase 1 shipped in v1.32.x) was the first instrumentation step; Phases 2-4 (token analysis, baseline comparison, firing-rate × cost cutoff) remain deferred. Worth resuming when classifier_telemetry data accrues enough to make the deltas statistically distinguishable.
- **Conf-flag interactions.** The bias-defense flags can fight each other across long sessions (the test-isolation conf-leak case is the canonical symptom). A composability matrix in `docs/customization.md` would be the cheap win.
- **FINDINGS_JSON brittleness across model versions.** Currently regression-netted by `tests/test-findings-json.sh` against the contract shape. Worth re-running the regression set against new Claude model releases (Sonnet/Opus/Haiku rev bumps) before assuming the JSON shape will hold.
- **Classifier accuracy without formal eval.** `tools/classifier-fixtures/regression.jsonl` exists; a precision/recall surface against a labeled corpus would let directive tuning be evidence-driven rather than vibes-driven.

These are recorded here (not as open issues) because they're polish work for an already-stable paradigm, not blockers for a shift to a different one.
