# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed

- **Gate-message tone pass.** Replaced the redundant `Autowork guard:` framing in five `stop-guard.sh` block messages and both `pretool-intent-guard.sh` block paths with the action-first bracketed-prefix style already used elsewhere (`[Quality gate · 1/3] The deliverable changed but…` / `[PreTool gate · 2/2 · advisory] Destructive git/gh operations…`). The bracketed gate label already self-identifies the source — the prefix was duplicating that identity in legalese tone, which the design-lens flagged as reading "you got caught" rather than "here's what's left". Behavior is unchanged; the test-e2e-hook-sequence assertions at `gap8s` updated to assert the new `PreTool gate · N/M` counter format instead of the legacy `block #N` phrasing.
- **README skill table reorganized for scannability.** Skills now group by intent ("Run a task", "Think before acting", "Review & evaluate", "Build", "Workflow control"), each mythology-named skill carries a parenthetical mnemonic (`metis (stress-test)`, `oracle (second opinion)`, etc.), and the alias headline `> Aliases /autowork, /ultrawork, and sisyphus also trigger…` is demoted to a footnote that distinguishes preferred aliases from legacy `sisyphus` (which keeps working for muscle memory but stops competing for attention in the discovery surface). Cross-links into the new `docs/glossary.md` from both the README footnote and `skills/skills/SKILL.md`.

### Added

- **`docs/glossary.md` — decoder ring for mythology-named skills and agents.** New ~100-line glossary explaining each name (atlas, metis, oracle, prometheus, librarian, council, ulw-* family) plus the agents (`*-lens` family, the reviewer trio, specialist developers) and the harness's internal terms (quality gate, wave, Council Phase 8, discovered scope, Serendipity Rule, ULW mode). Searchable by verb so users who can't remember "the plan command" can find it. Closes the design-lens "no decoder ring for mythology names" gap.
- **`/ulw-demo` Beat 7 — first-task bridge.** New step at the end of the demo (`BEAT 7/7 · NEXT`) that detects the user's project type by inspecting CWD and offers three concrete copy-paste prompts tailored to what was found (code project / docs project / mixed / fresh-install fallback). Closes the post-demo cliff the design-lens flagged: the demo's value-moment was real, but users left without an obvious next step that wasn't "type `/ulw` and hope". Also updates the staleness fallback note — `/ulw-demo` already auto-activates ULW mode via `is_ulw_trigger` (since v1.9.x), so the previous "ask the user to run /ulw first" advice was outdated.

### Added

- **`/ulw-report` skill — cross-session activity digest.** New user-invocable skill that renders a markdown report joining `~/.claude/quality-pack/` aggregates: `session_summary.jsonl` (sessions, edits, gate fires, skips, dispatches, reviewer/exhaustion flags, Serendipity counts), `serendipity-log.jsonl` (recent fixes), `classifier_misfires.jsonl` (top misfire reasons), `agent-metrics.json` (top reviewers + finding rate), and `defect-patterns.json` (defect category histogram). Also surfaces Phase 8 finding/wave outcomes (shipped/deferred/rejected/pending; waves planned vs. completed) for sessions with a swept `findings.json`. Modes: `last`, `week` (default), `month`, `all`. Implementation: `bundle/dot-claude/skills/ulw-report/SKILL.md` + `bundle/dot-claude/skills/autowork/scripts/show-report.sh` (~230 lines). Closes the post-v1.12.0 council triangulation point — product, data, and growth lenses all converged on "the harness has rich telemetry but no human-readable surface".
- **Outcome attribution in `session_summary.jsonl`.** `record_gate_skip` now increments a per-session `skip_count` under `with_state_lock` (separate from `with_skips_lock` — never nests, no deadlock). `sweep_stale_sessions` joins each session's state with its `findings.json` (if present) so swept rows now also carry `skip_count`, `serendipity_count`, `findings: {total, shipped, deferred, rejected, in_progress, pending}`, and `waves: {total, completed}`. Existing fields are unchanged. Schema additions are additive — all readers that consume the aggregate (including `show-status.sh`) continue to work.
- **`tests/test-show-report.sh`** — 32 assertions across 10 cases: argument parsing, exit codes (`--help` → 0, unknown mode → 2), empty-state rendering, populated rendering with synthesized `session_summary.jsonl`, `last`-mode tail selection, time-window filtering (week/month exclude 60-day-old rows that `all` includes), Serendipity rendering with multiple rows, classifier-misfire reason aggregation, agent-metrics reviewer table with computed find-rate, and defect-pattern histogram.

### Changed

- **Prompt classifier extracted to `lib/classifier.sh`.** Second slice of the planned `common.sh` decomposition (state-I/O extracted in v1.12.0). Eight functions move out: `is_imperative_request` (P0 imperative detection), `count_keyword_matches`, `is_ui_request`, `infer_domain` (P1 domain scoring), `classify_task_intent` (top-level dispatcher), `record_classifier_telemetry`, `detect_classifier_misfire`, and `is_execution_intent_value`. ~496 lines move from `common.sh` (3329 → 2846, **−14%**) into a focused 528-line module with a documented dependency contract. **No behavior change** — every classifier test passes unchanged: `test-intent-classification.sh` (441 assertions), `test-classifier-replay.sh` (15), `test-common-utilities.sh` (359), and the integration suites `test-e2e-hook-sequence.sh` (326) and `test-discovered-scope.sh` (79). `_omc_self_dir` now stays in scope through end-of-file so multiple libs can be sourced; `verify.sh` `required_paths` and the `AGENTS.md` architecture diagram updated to list the new lib alongside `lib/state-io.sh`. The classifier subsystem is now the single point of contact for future regex tuning, classifier retraining, and dedicated regression tests.

### Added

- **`tests/test-classifier.sh`** — focused symbol-presence + sourcing-order regression net for the new lib. 29 assertions across 7 test cases: all 8 contracted functions are defined after `common.sh` source, lib file exists, parses under `bash -n`, has no stray top-level invocations, every named dependency resolves to a definition strictly above the source statement in `common.sh`, smoke-checks `classify_task_intent` against canonical execution/advisory prompts, and asserts `is_execution_intent_value`'s execution/continuation/advisory/checkpoint contract.

### Documentation

- **`docs/architecture.md` and `docs/customization.md` updated for the lib extraction.** The Shared Library section now reflects the `(~2,850 lines, with two subsystems extracted to lib/)` reality (was claiming `~516 lines`, stale since well before v1.12.0). The customization-guide "Domain Keywords" section now points at `lib/classifier.sh` and drops a brittle "around line 320" reference. Both fixes applied under the Serendipity Rule during Wave 2 (verified, same documentation surface as the wave's primary diff, bounded copy edit).

### Fixed

- **Cross-session JSONL caps consolidated; `serendipity-log.jsonl` now bounded.** v1.12.0 added a Serendipity cross-session aggregate but no rotation, leaving `~/.claude/quality-pack/serendipity-log.jsonl` to grow unbounded across years of accrual. The fix introduces `_cap_cross_session_jsonl <file> <cap> <retain>` in `common.sh` and routes the existing `classifier_misfires.jsonl` (1000/800), `session_summary.jsonl` (500/400), and `gate-skips.jsonl` (200/150) caps through it, then adds a fourth call site for `serendipity-log.jsonl` (2000/1500). The first three call sites live inside `sweep_stale_sessions` (single-writer, gated by the daily marker file); the gate-skips call site runs hot-path inside `record_gate_skip` under its own `with_skips_lock` flock. Helper documents the one residual race (in-flight unlocked appends from `record-serendipity.sh` between the cap's `tail` and `mv` — at most one analytics row lost per cap-fire, fires at most once per 24h). New `tests/test-cross-session-rotation.sh` (15 assertions across 10 cases) covers helper existence, missing-file no-op, under/at/over-cap behavior, tail-semantics row-preservation, idempotence, temp-file cleanup, an anti-regression assertion that no open-coded `tail-N`/`mv` cap idiom remains for known cross-session aggregates outside the helper, and per-call-site argument symmetry.

## [1.12.0] - 2026-04-25

First-cycle technical-debt-and-analytics close-out following v1.11.1. Three independent waves: extract the state-I/O subsystem out of the growing `common.sh` monolith into a focused `lib/state-io.sh` module (no behavior change); close the v1.9.0 telemetry data loop with a curated-fixture replay tool that detects classifier drift on every PR; and close the v1.8.0 deferred Serendipity Rule analytics by adding a `record-serendipity.sh` helper that logs each rule application to per-session and cross-session JSONL plus state counters surfaced in `/ulw-status`.

### Added

- **Serendipity Rule analytics (`record-serendipity.sh`).** New autowork helper closes the loop on whether the Serendipity Rule (verified-adjacent-defects-fixed-in-session, from `core.md`) is being applied or silently ignored. Each rule application logs a JSON record to `<session>/serendipity_log.jsonl` (per-session) and `~/.claude/quality-pack/serendipity-log.jsonl` (cross-session aggregate), and increments three new state keys: `serendipity_count`, `last_serendipity_ts`, `last_serendipity_fix`. Counter and last-fix description surface in `/ulw-status` full mode under `--- Counters ---`. Concurrent invocations preserve all writes via the existing `with_state_lock` primitive (8-op stress test in `tests/test-serendipity-log.sh`). Hook-style guard exits 0 on missing `SESSION_ID`; missing or malformed input exits 2 without partial writes. The Serendipity Rule in `core.md` now points to the helper with a one-liner invocation, so the logging path is discoverable from inside the rule itself. Closes a deferred item from v1.8.0 (Serendipity analytics target ~2026-04-30, landed early).

- **Classifier-telemetry feedback loop.** New developer tool `tools/replay-classifier-telemetry.sh` replays captured prompts against the current `classify_task_intent` / `infer_domain` and flags drift. Closes the v1.9.0 telemetry loop: `classifier_telemetry.jsonl` accumulates whether anyone reads it; this tool turns the data into a regression net. Modes: `--fixtures FILE` (default: `tools/classifier-fixtures/regression.jsonl`) for CI; `--live` for replaying against your own `~/.claude/quality-pack/state/*/classifier_telemetry.jsonl`. Exit code 0 = no drift, 1 = at least one row drifted, 2 = usage error. New CI test `tests/test-classifier-replay.sh` (15 assertions) wraps the tool — it asserts the curated fixtures are stable, exercises drift detection with an intentionally-mismatched row, validates the `--help` surface, and checks forward-compat with non-object rows. Initial fixtures (18 rows) cover the canonical execution / advisory / continuation / checkpoint / session-management cases plus mixed-intent and ULW-alias edge cases. Several rows have notes flagging suspected misclassifications captured for stability — future classifier improvements that fix them will trip the regression suite as expected, prompting an intentional fixture update.

### Changed

- **State I/O subsystem extracted to `lib/state-io.sh`.** First slice of the planned `common.sh` decomposition. The state-I/O block (≈210 lines: `ensure_session_dir`, `session_file`, `read_state`, `write_state`, `write_state_batch`, `append_state`, `append_limited_state`, `with_state_lock`, `with_state_lock_batch`, `_ensure_valid_state` recovery, `_lock_mtime` BSD/GNU stat compat) moved out of `common.sh` into `bundle/dot-claude/skills/autowork/scripts/lib/state-io.sh`. `common.sh` now sources the lib after `validate_session_id` and `log_anomaly` are defined. **No behavior change** — every existing test passes unchanged.
- **Symlink-aware sourcing.** `common.sh` now resolves its own path through a portable readlink loop before sourcing the lib. This works whether `common.sh` is installed normally (rsync recursion handles `lib/` automatically), symlinked from a test HOME (e.g. `tests/test-e2e-hook-sequence.sh`), or symlinked to a user's custom location. Without this, the test harness — which symlinks just `common.sh` — would lose the `lib/` reference. Compatible with BSD `readlink` (macOS) and GNU `readlink` (Linux); no `realpath` dependency.

### Added

- **`tests/test-state-io.sh`** — focused regression suite for the extracted module. 26 assertions across 12 test cases: missing-key reads, write/read round-trip, jq `--arg` escaping for shell-special characters, `write_state_batch` atomic multi-key, odd-arg rejection without partial mutation, plain-file read fallback, corrupt-JSON recovery via `_ensure_valid_state` (including archive-file creation), `with_state_lock` serialization under 5 concurrent writers, stale-lock recovery, `with_state_lock_batch` one-shot atomicity, `append_limited_state` truncation, and `session_file` path shape. `verify.sh` required-paths list, AGENTS.md / CONTRIBUTING.md / CLAUDE.md / README.md test listings all updated in lockstep.

## [1.11.1] - 2026-04-25

Stabilization release following v1.11.0 (Council Phase 8). Closes the doc-drift gap that left Phase 8 invisible in the user-facing skill table and customization guide, plugs test gaps in the wave-aware discovered-scope cap and the finding-list lock, lands a deferred `auto_memory` conf key for shared machines / regulated codebases, and trims nine specialist agent descriptions that had grown unmanageable.

### Added

- **`auto_memory` conf key (default `on`).** New per-project / per-user opt-out for the auto-memory wrap-up rule (`memory/auto-memory.md`) and compact-time memory sweep (`memory/compact.md`). Set `auto_memory=off` in `~/.claude/oh-my-claude.conf` (user-level) or `<repo>/.claude/oh-my-claude.conf` (project-level, walked up from CWD) to suppress automatic `project_*.md` / `feedback_*.md` / `user_*.md` / `reference_*.md` writes at session-stop and pre-compact moments. Explicit user requests ("remember that...", "save this as memory") still apply regardless. Same conf precedence as other oh-my-claude tunables: env (`OMC_AUTO_MEMORY`) > project > user > default. Use this on shared machines, regulated codebases, or projects where session memory should not accrue across runs. Closes a deferred item from the v1.8.0 cycle. New `is_auto_memory_enabled()` helper in `common.sh` exposes the resolved value to instruction text — the auto-memory.md and compact.md rules now embed a one-liner that calls it before applying.

### Changed

- **Nine specialist agent descriptions trimmed.** `frontend-developer`, `backend-api-developer`, `devops-infrastructure-engineer`, `fullstack-feature-builder`, `test-automation-engineer`, `ios-core-engineer`, `ios-ui-developer`, `ios-deployment-specialist`, and `ios-ecosystem-integrator` carried multi-block `<example>` XML inside their YAML `description:` field — visually unmanageable (~3× longer than peer agents like `prometheus`/`oracle`) and harder to scan in the `/agents` picker. Each is now a single 1–2 sentence purpose statement covering scope and key technologies. Body content (role description, capabilities, guidelines) is unchanged. Discoverability improvement, not a parsing fix — the prior YAML still parsed correctly because escaped newlines and angle brackets inside a quoted string are valid YAML.

### Fixed (post-review)

- **`compact.md` auto_memory opt-out is now enforced, not informational.** The first-pass auto_memory implementation embedded the executable `is_auto_memory_enabled` check in `auto-memory.md` but wrote only a cross-reference note in `compact.md` ("applies here too"). On long sessions, the compact-time memory sweep would still write memory even when `auto_memory=off`, defeating the opt-out's purpose. `compact.md` now embeds the same `bash -c '. .../common.sh; is_auto_memory_enabled' || skip` one-liner so the flag is honored at both wrap-up AND compact moments. Surfaced by the v1.11.1 quality-reviewer pass.

### Documentation

- **README skill table now surfaces Council Phase 8 and wave-plan visibility.** The 1.11.0 headline feature was invisible from the README — the `council` row described evaluation only, and the `ulw-status` row didn't mention the wave-plan progress display. Both rows now call out Phase 8 / wave-by-wave execution and the wave-plan progress surface respectively.
- **docs/customization.md tunables table gains four missing conf keys**: `gate_level` (`full`|`standard`|`basic`), `guard_exhaustion_mode` (`scorecard`|`block`|`silent` plus legacy aliases), `discovered_scope` (with the `N+1` cap-raise note for active wave plans), and `council_deep_default`. All four were documented in `CLAUDE.md` but absent from the user-facing tuning surface, so users couldn't discover or tune them without reading source.
- **`--no-ios` description corrected** from "5 iOS-specific specialist agents" to "4". The flag removes `~/.claude/agents/ios-*.md` files (4 files); the prior text padded the count with `frontend-developer`, which is not removed and is not iOS-specific.
- **AGENTS.md test-script listings now include `test-discovered-scope.sh` and `test-finding-list.sh`** in both the architecture diagram and the testing-commands block. Both tests existed since 1.10.0 and 1.11.0 respectively but the listing had not been updated. Surfaced under the Serendipity Rule during the v1.11.1 doc-drift sweep.

### Testing

- **Wave-aware discovered-scope cap boundary tests** in `tests/test-discovered-scope.sh`: 1-wave plan → cap=2 (smallest valid plan), 10-wave plan → cap=11 (large plan stays useful), and a regression test asserting the cap formula uses `wave_total`, not `wave_total - waves_completed`, so the gate stays useful across the full wave plan instead of shrinking as waves complete. Plus a non-contiguous-completion test for `read_active_waves_completed` (waves 1, 2, 4 marked → returns 3, not the indices).
- **High-concurrency stress in `tests/test-finding-list.sh`**: a 12-simultaneous-status-update test (Test 17 covered 3 ops; the new test exercises the lock-acquisition path under real Phase 8 wave-execution load) plus an 8-op mixed-stress test that interleaves `status`, `assign-wave`, `add-finding`, and `wave-status` to mirror real wave-execution traffic. Both assert post-storm JSON validity, no lost writes, and lock-directory cleanup.
- **Total bash test coverage:** 1,639 → 1,666 assertions (+27) across 14 bash test scripts plus the python statusline suite (15 test scripts total).

## [1.11.0] - 2026-04-25

Council-to-execution bridge. The longstanding gap between "council surfaced 30 findings" and "now ship them all with rigor" is now closed — `/council` has a Phase 8 (Execution Plan) that runs wave-by-wave with full plan/review/excellence/verify/commit per wave instead of collapsing into a single-shot mega-implementation that exhausts context and clips scope to the five-priority headline.

### Added

- **Council Phase 8 (Execution Plan).** When the user's prompt asks for fixes (markers: "implement all", "exhaustive", "fix everything", "make X impeccable", "address each one"), council no longer ends at Step 7's presentation. Phase 8 builds a master finding list with stable IDs, groups findings into 5–10-finding waves by surface area, and executes each wave fully — `quality-planner` for the wave's findings, implementation specialist, `quality-reviewer` on the wave's diff (small enough for real signal), `excellence-reviewer` for the wave's surface area, verification, per-wave commit titled `Wave N/M: <surface> (F-xxx, ...)`, and findings-list status update — before starting the next wave. Skipped on advisory-only prompts ("just analyze", "report only"). Documented in `bundle/dot-claude/skills/council/SKILL.md` and auto-injected by `prompt-intent-router.sh` when council fires under execution intent.
- **`record-finding-list.sh` script.** New autowork helper that persists the council Phase 8 master finding list to `<session>/findings.json` with stable IDs, status (pending/in_progress/shipped/deferred/rejected), wave assignment, commit SHAs, and notes. Subcommands: `init`, `path`, `status`, `assign-wave`, `wave-status`, `show`, `counts`, `summary` (markdown table for the final report). Atomic writes guarded by file lock to handle concurrent SubagentStop hooks.
- **Wave-aware discovered-scope cap.** When a council Phase 8 wave plan is active (`findings.json` declares N waves), the discovered-scope gate raises its block cap from 2 to N+1 so the gate stays useful across multiple legitimate wave-by-wave commits instead of silently releasing after wave 2 with 20+ findings still pending. Pre-existing 2-block cap is preserved when no wave plan is active. New helpers `read_active_wave_total` and `read_active_waves_completed` in `common.sh`.
- **Sixth pause case in `core.md`: scope explosion without pre-authorization.** When an assessment surfaces ≥10 findings and the prompt did NOT explicitly authorize exhaustive implementation, the model surfaces the wave plan and confirms cadence before starting. Authorization tokens like "implement all", "exhaustive", "every item", "ship it all", "address each one", "fix everything" ARE the green light to proceed without re-asking — the pause exists to prevent surprise context exhaustion on under-specified large-scope requests, not to add friction to clearly authorized work.

### Changed

- **Rule 8 in `autowork/SKILL.md` and core.md segmentation rule** now distinguish *cross-session* handoffs (forbidden) from *in-session* wave structure (encouraged for council-driven implementation). "Wave 2/5 starting now" is correct narration; "stopping after wave 2, resume next session" remains the anti-pattern. Closes the conflict where the old blanket rule pushed the model into single-shot mega-implementations for large-scope requests.
- **Five-priority rule in `council/SKILL.md`** clarified: the rule governs *presentation* order (top of report), not *execution* scope. When the user requests exhaustive implementation, all findings flow into the Phase 8 wave plan; the rank only determines wave ordering. The most-common misreading — silently clipping execution scope to the top 5 — is the failure mode this clarification prevents.

### Fixed (post-review)

- **`record-finding-list.sh` / `show-status.sh` session discovery picked flat files as `SESSION_ID`.** Both scripts used `ls -t | head -1` over `STATE_ROOT`, which legitimately contains `hooks.log` (touched on every hook fire) and `installed-manifest.txt` alongside session-UUID directories. When a flat file was the most recently modified entry, `record-finding-list.sh` died with `mkdir: File exists` (Phase 8 unable to record findings); `show-status.sh` failed gracefully but printed `Session hooks.log has no state file`. Reproduced live; fixed by replacing the discovery loop with a directory-only shell glob (`for d in "${STATE_ROOT}"/*/`). Same root-cause family in both scripts — second fix surfaced under the Serendipity Rule.
- **Session-discovery logic now lives in `common.sh::discover_latest_session()`** instead of being duplicated across `record-finding-list.sh` and `show-status.sh`. The two copies were textually equivalent at landing, but any future fix (mtime ties, lstat handling, symlinked sessions) was guaranteed to skip one of them. Reviewer-flagged future-maintainer trap closed by extraction.
- **`read_active_wave_in_progress` was misnamed** — it counts waves with `status="completed"`, not `in_progress`. Renamed to `read_active_waves_completed` in `common.sh` with the test and stop-guard call site updated. Future-maintainer trap closed.
- **`init` now refuses to overwrite an active wave plan.** Without this guard, a model resuming a session after compaction or a crash could blindly re-run `init` and clobber `waves[]`, losing every shipped/commit-tracked finding. Default behavior now refuses with an actionable error pointing to `counts`/`show`; `--force` overrides for legitimate "start over" scenarios. Both branches covered by 3 new tests.
- **New `add-finding` subcommand** for the discover-during-execution case where a wave reveals a finding the council missed. Without this, `assign-wave` would silently skip unknown IDs (it filters `.findings | map(...)`), causing newly-named findings to never appear in counts or summary. The subcommand validates the input is an object with an `id` field and rejects duplicates. Documented in council SKILL.md §8.4 and the Phase 8 router hint.
- **`_acquire_lock` trap installation moved before the mkdir retry loop.** A SIGINT delivered between `mkdir` success and `trap` install would have orphaned the lock directory. Trap is now installed first; the trap's `rmdir` is a safe no-op when the lock dir doesn't yet exist, and the trap is cleared on lock-acquisition timeout to avoid interfering with the caller's own trap chain.
- **`omc-repro.sh` now bundles `findings.json` and `discovered_scope.jsonl`.** Bug reports about Phase 8 wave behavior or the discovered-scope gate previously arrived without the wave plan or finding list, making maintainer reproduction impossible. Both files contain model-derived content (severity, surface, summaries) — no verbatim user prompt text — so they're added to the unconditional copy loop without redaction.
- **Phase 8 router hint never named the bootstrap command.** The injected guidance referenced `findings.json` but didn't tell the model how to create it. Models under context pressure that only see the router-injected hint (without paging in the council skill) would write JSON manually or skip persistence. Hint now includes the exact `record-finding-list.sh init <<< '<json>'` invocation, plus `assign-wave`, `status`, `add-finding`, `summary`, and a resume-check note.
- **`/ulw-status` now surfaces wave-plan progress** — waves completed/in-progress, current surface area, and finding shipped/pending counts. Closes the visibility gap so the user can ask "where am I in the plan?" without invoking `record-finding-list.sh show`.
- **`enterprise-polish` framing was named but not wired.** Council Phase 8 step 4 instructed dispatching `excellence-reviewer` with an "enterprise-polish framing" but the reviewer agent had no such mode. Replaced with an explicit inline checklist (error/empty/loading states, copy tone, accessibility WCAG AA, edge cases, transitions/reduced-motion, dark-mode/RTL) so the dispatch site carries the bar instead of pretending a non-existent mode exists.
- **`reset_scope()` test helper now clears `findings.json`.** Previously left it behind, which would have silently raised the discovered-scope cap in subsequent tests if test order changed.
- **Stale doc counts in CLAUDE.md, AGENTS.md, README.md.** CLAUDE.md said "14 autowork hook scripts" (actual: 15); AGENTS.md said "13 autowork hook scripts"; README.md said "13 test scripts". All reconciled to actual counts (15 autowork, 15 test scripts incl. python statusline). CHANGELOG assertion-count claim corrected from "1,621 → 1,627" to "1,571 → 1,627" (+56) — the original baseline number was wrong.

### Testing

- 4 new test cases in `tests/test-discovered-scope.sh` covering wave-aware cap behavior (cap=2 default, cap=N+1 with N-wave plan, malformed findings.json fails open, completed-wave count helper).
- New `tests/test-finding-list.sh` (53 assertions across 25 test cases, including a concurrency test that backgrounds 3 simultaneous status/wave writes and verifies the file lock prevents JSON corruption, plus 12 assertions covering the `init`-overwrite guard, `init --force` override, and `add-finding` subcommand) covering all script subcommands, atomic status updates, idempotent wave assignment, markdown summary rendering with pipe-escape, and error handling.
- Total bash test coverage: 1,571 → 1,639 assertions (+68) across 13 → 14 bash test scripts plus the python statusline suite (15 test scripts total).

## [1.10.2] - 2026-04-24

Quality-first follow-on to 1.10.0/1.10.1: `/ulw`-triggered councils can now inherit `--deep` automatically.

### Added

- **`council_deep_default` conf key (default `off`).** Quality-first users on `model_tier=quality` (or anyone willing to pay for opus-grade lens reasoning on every auto-triggered council) can set `council_deep_default=on` in `~/.claude/oh-my-claude.conf` (env: `OMC_COUNCIL_DEEP_DEFAULT`). When on, the prompt-intent-router's auto-dispatch path (broad project-evaluation prompts that match `is_council_evaluation_request`) extends its injected guidance with: pass `model: "opus"` to each Agent dispatch + the deep-mode instruction extension. Explicit `/council --deep` invocations are unaffected (they always escalate); explicit `/council` without `--deep` is also unaffected (only the auto-detected dispatch path changes).
- **Inline `--deep` propagation through `/ulw`.** When the user types `/ulw evaluate the project --deep` (or any prompt containing `--deep` as a standalone token AND triggering council auto-detection), the router now propagates the `--deep` intent into the council dispatch guidance regardless of the conf flag. Closes the gap where `--deep` was visible to the main thread but not surfaced to the auto-triggered council.
- **Phase 7 verification surfaced in auto-triggered councils.** The router-injected council protocol now includes a Step 7: re-verify the top 2-3 highest-impact findings via focused `oracle` dispatches before presenting. Previously this was only documented in the `/council` skill itself; auto-triggered councils that bypassed reading the skill missed the verification phase. The router and skill are now in sync.
- **Synthesis evidence-rejection in auto-triggered councils.** Step 5 of the injected guidance now explicitly says "Reject findings that lack file/line evidence." Mirrors the rule already present in the council skill's synthesis section.

### Testing

- 4 new assertions in `tests/test-common-utilities.sh` covering `council_deep_default` default-off, conf-on, invalid-value rejection, and env-beats-conf precedence.

## [1.10.1] - 2026-04-24

Hotfix release for four prompt-hygiene defects caught in a post-1.10.0 review pass. All four affect agent/skill prompt structure rather than executable code, so no test changes were needed; verify.sh and the existing 13 bash test scripts + 82 python tests all continue to pass.

### Fixed

- **`briefing-analyst.md` VERDICT-line contract violation.** The Wave 2 "Tension preservation" section was placed *after* the Return list's final item — which contains the directive "End with exactly one line on its own, unindented, as the final line of your response: `VERDICT: ...`". The stop-guard reads the last line of agent output to tick the `traceability` dimension; an agent following the prompt sequentially would emit prose after the VERDICT line, breaking the dimension tick. Moved the Tension-preservation block above the Return list so the VERDICT directive is once again the final instruction. Same class of bug 1.10.0's prompt-edit pass was meant to prevent — caught one in the review.
- **`/council` Step 6 / Phase 7 naming collision.** The verification step was added as `### 6. Verify top findings (Phase 7 of execution, named here for ordering)`, then cross-referenced as "Phase 7 below" elsewhere — forcing an LLM under context pressure to resolve two different names for the same step. Renamed everywhere to consistent "Step 6". The skill's job is to survive compaction; naming collisions undercut that.
- **Typo in `/council` Step 6 copy.** "findings that load-bearing" → "findings that are load-bearing".
- **`/council --deep` argument-form ambiguity.** The original spec said "if `$ARGUMENTS` contains `--deep` as a standalone token, set DEEP_MODE" but did not specify what counts as standalone. A user typing `--deep=true` or `-deep` would silently get sonnet despite expecting opus. Added explicit guidance: only the bare `--deep` flag (whitespace-separated, anywhere in args) is recognized; variants are not.

## [1.10.0] - 2026-04-24

Council depth, completeness, and cognitive-scaffolding pass. The headline change is a new completeness gate that closes the "shipped 25 / deferred 8 / silently skipped 15" anti-pattern surfaced by an in-session council audit. Beyond that: every council lens, deep-thinking agent (`metis`, `oracle`, `briefing-analyst`), and the `excellence-reviewer` now state their limits explicitly; `metis` and `excellence-reviewer` apply a triple-check rule (recurrence × generativity × exclusivity) before flagging a finding as load-bearing; `/council` adds a Phase 7 verification pass that re-checks the top 2-3 findings via `oracle` before presenting; and `/council --deep` opt-in escalates lenses to opus for high-stakes audits. All shipped together because they are interlocking improvements to the same surface: how findings are discovered, validated, and prevented from being silently dropped.

**Live install staleness.** Existing in-flight sessions keep the previous hook bindings until restart. The new gate, telemetry, and council protocol are dormant on the live install until `install.sh` is re-run from the repo. The statusline `↑v1.10.0` indicator surfaces this automatically.

### Added

- **Discovered-scope tracking and completeness gate.** Closes the "shipped 25 / deferred 8 / silently skipped 15" anti-pattern surfaced by the v1.10.0 council-completeness audit. When advisory specialists (`metis`, `briefing-analyst`, and the six council lenses: `security-lens`, `data-lens`, `product-lens`, `growth-lens`, `sre-lens`, `design-lens`) return, `record-subagent-summary.sh` now extracts their numbered findings into a per-session `discovered_scope.jsonl` (one JSON object per row: `id`, `source`, `summary`, `severity`, `status`, `reason`, `ts`). Heuristic extraction is anchored on known section headings (`Findings`, `Risks`, `Recommendations`, `Concerns`, `Issues`, `Unknowns`, `Action items`) with a 3+ numbered-item fallback for free-form output; code-fenced lists are explicitly skipped to avoid capturing illustrative numbered logic. On every session stop attempt, `stop-guard.sh` reads the pending count and — when `task_intent` is `execution`/`continuation` and `OMC_DISCOVERED_SCOPE` is `on` (default) — blocks once with a severity-ranked scorecard if any findings remain unaddressed. Cap of 2 blocks per session matches the existing handoff gate. `/ulw-skip` clears the counter so an explicit user override always releases. The new `discovered_scope` conf key (env: `OMC_DISCOVERED_SCOPE`) is the kill switch when heuristic extraction proves too noisy on a project's prose style.
- **`excellence-reviewer` reads `discovered_scope.jsonl`.** New evaluation axis #6 ("Discovered-scope reconciliation") instructs the reviewer to read the per-session findings ledger and categorize every `pending` row as shipped (with file/line evidence), explicitly deferred (with stated reason), or silently dropped. Silently-dropped findings flow into the existing FINDINGS verdict count, so the completeness dimension now explicitly checks discovered scope, not only the original `current_objective`.
- **`/ulw-status` shows discovered-scope counters.** Full-status mode adds a `Discovered-scope:` row in counters and a `Discovered findings: X total · Y pending · Z shipped · W deferred` line. Summary mode (`--summary`) adds `scope=<n>` to the `Blocks:` line when the gate fired during the session.
- **New common.sh helpers** for the same surface: `discovered_scope_capture_targets`, `extract_discovered_findings`, `with_scope_lock`, `append_discovered_scope` (dedupes by content-hash id, caps at 200 rows FIFO), `read_pending_scope_count`, `read_total_scope_count`, `build_discovered_scope_scorecard`, `update_scope_status`. All entry points fail open: a noisy parse that captures nothing is preferable to a blocked stop.

### Testing

- **New `tests/test-discovered-scope.sh`** — 46 assertions across 22 test cases covering: extraction on canonical security-lens output (numbered findings + recommendations + unknowns), metis numbered findings, dash/star bullet capture under anchored headings (BSD-awk-portable case-insensitive matching), fail-open on garbage / empty / code-fenced input, dedup on repeat append (cross-batch + within-batch), 200-row FIFO cap, capture-target whitelist (includes all six lenses + metis + briefing-analyst, excludes verifiers), severity heuristic mapping (critical → high, medium → medium, default → low), gate firing twice then releasing on cap, advisory-intent bypass, no-file bypass, kill-switch via `OMC_DISCOVERED_SCOPE=off`, malformed-JSONL resilience (single corrupt row no longer disables the gate), instruction prose with no finding-language NOT triggering fallback, `/ulw-skip` releasing the counter, `update_scope_status` round-trip with full id, and short-prefix rejection.

### Changed

- **Specialist agents now state their limits.** Every council lens (`security-lens`, `design-lens`, `data-lens`, `sre-lens`, `growth-lens`, `product-lens`) plus `oracle`, `metis`, and `briefing-analyst` now end their output with a `### What this lens cannot assess` (or "stress-test cannot catch" / "analysis cannot determine" / "brief cannot resolve") section. This is borrowed from the nuwa-skill methodology: agents that don't tell you their limits cannot be trusted at the limit. Surfacing scope explicitly prevents the main thread from over-trusting a single-perspective output and helps it route remaining questions to the right next specialist.
- **`metis` and `excellence-reviewer` gain a triple-check rule.** Before flagging a finding as load-bearing, the agent must confirm three properties: (a) **recurrence** — the pattern shows up in 2+ unrelated parts of the codebase/plan, not a one-off; (b) **generativity** — the finding predicts a specific concrete change, not a generic recommendation; (c) **exclusivity** — a senior practitioner catches this, not what every reasonable engineer would say. A finding that fails all three is opinion, not signal — either reframe as a minor note or drop. Reduces noise from generic "add tests / add error handling" critiques and keeps reviewer output decision-useful.
- **`briefing-analyst` now preserves tensions instead of synthesizing them away.** When source material contains genuine contradictions, the agent surfaces them explicitly ("Source A says X; Source B says Y; the conflict is unresolved because Z") rather than producing a smooth narrative that hides disagreement.
- **`/council` Phase 7: verify the top of the stack before presenting.** After synthesis, the council skill now re-verifies the top 2-3 highest-impact findings via focused `oracle` dispatches (one per finding, opus, with the lens-cited evidence). Each finding is then marked ✓ verified, ◑ refined, or ✗ demoted/dropped in the final assessment. This addresses the "lens findings are surface-level" failure mode the Wave 0 audit surfaced: lens agents are sonnet single-pass with no recursion, so the highest-impact items needed a second pass before the user acted on them. Cap at 3 to keep verification bounded.
- **`/council` gains an Agentic Protocol block.** Embedded at the top of the skill, restated load-bearing rules survive context compaction: ground every finding in evidence; do not synthesize on partial returns; verify the top of the stack before presenting; preserve tensions; the five-priority rule. Borrowed from the nuwa-skill methodology of pinning agent behavior inside the skill rather than relying solely on global CLAUDE.md.
- **`/council --deep` flag escalates lenses to opus.** New optional argument. When `--deep` is passed, the council passes `model: "opus"` to each Agent dispatch, overriding the lenses' built-in `model: sonnet`. Cost is meaningfully higher per run; reserve for high-stakes audits, post-incident reviews, or cases where a previous shallow pass missed something.

## [1.9.2] - 2026-04-24

### Fixed

- **`/ulw-demo` skill could not activate ULW mode.** The ULW activation regex in `prompt-intent-router.sh:139` used `(^|[^[:alnum:]_-])(ultrawork|ulw|autowork|sisyphus)([^[:alnum:]_-]|$)` — with `-` included in the boundary exclusion class to prevent false positives on compound tokens like `preulwalar`. But that same exclusion meant `/ulw-demo` failed the right-boundary check (the `-` after `ulw` is in the set), so the router silently took the non-ULW path. Every downstream PostToolUse / Stop hook short-circuits when `is_ultrawork_mode` is false, so the entire demo fired zero gates despite the skill's explicit promise that "this demo MUST trigger real quality gates." Symptom was reproducible by invoking `/ulw-demo` from a fresh session: edits were made, `[Quality gate]` never fired, stop succeeded on the first try. Fix adds `ulw-demo` as an explicit alternative and extracts the regex into `common.sh::is_ulw_trigger` so it can be unit-tested. **Debug note for future regressions:** hook-script changes take effect only on a fresh Claude Code session — `UserPromptSubmit`, `PostToolUse`, and `Stop` bindings are loaded at session start, so an in-flight session keeps the old regex even after `install.sh` re-syncs the bundle. If `/ulw-demo` still appears broken after a fix, restart Claude Code before investigating further.

### Added

- **`is_ulw_trigger` helper in `common.sh`** — single source of truth for the "does this prompt trip ULW mode" predicate. Previously the regex was inlined at `prompt-intent-router.sh:139` with no test coverage. Now lives alongside `is_ultrawork_mode` and `workflow_mode` as a composable helper the test suite can call directly.

### Testing

- **New "ULW trigger detection" block in `tests/test-intent-classification.sh`** — 18 assertions covering canonical keywords (`ulw`, `ultrawork`, `autowork`, `sisyphus`, `/ulw`, case-insensitive `ULW`), the `/ulw-demo` regression case (bare, with leading `/`, mid-sentence), substring false-positive guards (`ulwtastic`, `preulwalar`, `culwate`, `ultraworking`, `autoworks`), and compound hyphen edges (`ulw-demos` must not match, `ulw-demo-fork` must not match). Total suite grows from 423 to 441 assertions.

### Documentation

- **`/ulw-demo` SKILL.md gains chapter-marker banners** — each of the 6 demo beats (`INTRO`, `EDIT`, `STOP-GUARD`, `VERIFY`, `REVIEW`, `SHIP`) now prints a `━━━ BEAT N/6 · LABEL ━━━` banner to the transcript. Designed as visible chapter markers for README GIF recordings so a viewer can pick up the flow without narration. Also added a fallback tip: if the stop-guard does not fire on Beat 3, the demo instructs the user to run `/ulw <anything>` first to flip the session into ultrawork mode.
- **Demo GIF added to README** — `docs/ulw-demo.gif` (2.8 MB, 800×418, 5 fps) replaces the commented-out placeholder. PII-redacted via 400 px top crop (removes terminal prompt with username/hostname), palette-optimized with gifsicle. Shows the full `/ulw-demo` flow: BEAT banners, edit tracking, stop-guard block, verification, reviewer catch, fix, and ship.

## [1.9.1] - 2026-04-24

Hotfix release for two defects caught in post-1.9.0 upgrade notes.

### Fixed

- **`omc-repro.sh` classifier-telemetry privacy leak.** The 1.9.0 writer in `record_classifier_telemetry` (`common.sh`) wrote the truncated prompt under JSON key `prompt`, but the redactor in `omc-repro.sh` targeted `prompt_preview`. Because `redact_jsonl_field`'s jq filter uses `has($field)` as a guard, the mismatch silently passed every telemetry row through unredacted — leaking the full 200-char prompt snippets into bug-report bundles despite the advertised redaction contract at `omc-repro.sh:12`, `:25`, and `:275`. Same class of bug 1.9.0 already fixed for `session_state.json` and `recent_prompts.jsonl`; one file slipped the net. The writer key is now `prompt_preview`, matching the header docstring at `common.sh:2731` and the redactor target. `show-status.sh --classifier` reader prefers `.prompt_preview` with a `.prompt` fallback so in-flight session files written under the old key stay readable for the remainder of their lifetime (100-row cap makes this self-healing within a session).
- **Dead CI-detection gate in `install.sh`.** Line 851's interactive-tip guard checked `[[ "${CI:-}" != "1" ]]`, but GitHub Actions, GitLab CI, CircleCI, Travis, and Buildkite all export `CI=true` — none set `CI=1`. The check never fired in any mainstream CI; the adjacent `[[ -t 0 ]]` TTY guard was doing all the work. Changed to `[[ -z "${CI:-}" ]]`, which catches `CI=true` (standard), `CI=1` (legacy/custom), and any other truthy value a runner might set.

### Testing

- `tests/test-repro-redaction.sh` **new** — end-to-end regression for the privacy contract. Writes a 200-char prompt via the real `record_classifier_telemetry`, runs the real `omc-repro.sh` against the fixture session, extracts the tarball, and asserts the bundled `prompt_preview` is exactly 80 chars (`REDACT_CHARS` default). 10 assertions. Verified it fails 3 assertions against the 1.9.0 code (writer key wrong + bundled length wrong) and passes cleanly after the field-name alignment — the test is a true regression test, not a tautology.

### Documentation

- **Test-list drift cleanup.** The "9 test scripts" count in `CLAUDE.md` and `README.md` was stale from pre-1.9.0 — 1.9.0 added `test-concurrency.sh`, `test-install-artifacts.sh`, and `test-post-merge-hook.sh` without updating the count or the per-file listings in `AGENTS.md` / `CONTRIBUTING.md` / `README.md` run-these-tests blocks. Updated all four docs in lockstep to the correct count (13 including the new `test-repro-redaction.sh`) with consistent per-file enumeration. This is the exact drift pattern the project's "add-to-all-four-docs-in-lockstep" rule was written to prevent.

## [1.9.0] - 2026-04-22

### Added

- **Bash-project test detection** — `detect_project_test_command` gains three new tiers so harness-style repos (pure bash with no language manifest) get a canonical test command. `justfile` with a `test:` recipe resolves to `just test`; `Taskfile.yml` with a `test` task resolves to `task test`; and pure-bash projects that have `run-tests.sh`, `scripts/test.sh`, `tests/run-all.sh`, or a `tests/test-*.sh` suite resolve to `bash <path>` with a deterministic precedence (explicit orchestrator > alphabetically-first `tests/test-*.sh`). Oh-my-claude itself now detects `bash tests/test-common-utilities.sh` instead of returning empty, closing the chicken-and-egg gap that 1.8.1's `verification_has_framework_keyword` fix worked around.
- **Bash-family match in `verification_matches_project_test_command`** — when the detected `project_test_cmd` is a concrete `bash <dir>/<file>.sh` invocation, any other `bash <dir>/<file>.sh` from the same directory now also matches and gets the +40 project-test-command bonus. Without this, pure-bash projects lost the bonus whenever the user ran a different test file than the one the detector picked (alphabetically first). Narrowed to the exact `bash <dir>/*.sh` shape so unrelated invocations (`bash other/foo.sh`, `cargo test`) stay correctly unmatched.
- **Stop-guard names the exact command in every block** — the low-confidence and missing-verify paths already named `${project_test_cmd}` in block 1; blocks 2–3's concise form now echo it too (`Still missing: low-confidence validation (run \`bash tests/test-foo.sh\`). Next: run \`bash tests/test-foo.sh\` for proper validation (current confidence: 30/100)`). Removes the "ok but WHICH command?" friction that the terse blocks created. Stop-guard additionally falls back to on-demand `detect_project_test_command` when state is empty, so the first missing-verify block gets the hint even before any verification has run.
- **Classifier telemetry loop** — every UserPromptSubmit now records a `{ts, intent, domain, prompt_preview, pretool_blocks_observed}` row to `classifier_telemetry.jsonl` in the session directory. On the following prompt, `detect_classifier_misfire` compares the prior row's `pretool_blocks_observed` against the current counter; if a PreTool block fired during a prior non-execution classification (advisory/session_management/checkpoint), a `misfire` annotation row is appended with a reason code (`prior_non_execution_plus_pretool_block`, or the stronger `prior_non_execution_plus_affirmation_and_pretool_block` when the current prompt is a bare "yes / do it / proceed / go ahead / ship it" affirmation). A negation filter (`no / don't / stop / cancel / never mind / that was wrong`) suppresses the log when the user explicitly walks back the prior attempt. At session sweep (TTL), misfire rows are aggregated into a cross-session ledger at `~/.claude/quality-pack/classifier_misfires.jsonl` for periodic regex-tuning review.
- **`/ulw-status --summary` mode** — `show-status.sh` gains a compact end-of-session recap showing session age, edit counts, unique files touched, dispatch count, verification status, reviewer verdicts, guard block tallies (stop, coverage, handoff, advisory, pretool), commits made during the session (from `git log --since=@<start_ts>`), classifier misfire count, and session outcome. Makes "invisible friction" signals visible on one screen so patterns like *"3 sessions in a row with mostly-misfire PreTool blocks"* become obvious instead of lost. Also accessible via the `/ulw-status summary` alias; the ULW-status skill routes `summary|-s|--summary` arguments to the new mode.
- **`/ulw-status --classifier` mode** — drills into the classifier telemetry directly: shows current-session rows (last 10 classifications + any misfires detected), cross-session misfire tallies grouped by prior intent and reason, and a pointer to the raw ledger. Intended for maintainers deciding whether to widen or tighten `is_imperative_request` / `is_advisory_request` regexes based on actual data rather than whack-a-mole feedback.
- **Opt-in `install.sh --git-hooks`** — writes `.git/hooks/post-merge` in the source checkout that compares `installed-manifest.txt` + bundle mtimes against `.install-stamp` after every merge (which includes `git pull`). When the bundle has drifted from the last install, the hook prints a yellow `[oh-my-claude] Bundle changes detected after merge.` banner with the installer command. Honors `OMC_AUTO_INSTALL=1` to install automatically without prompting (useful for CI / trusted environments). Never overwrites a non-oh-my-claude hook that already exists at `post-merge`; leaves it in place and tells the user to move it first. Does not abort the git operation on any branch.
- **`classifier_telemetry` config key** — gates the per-turn JSONL recording. `on` (default) keeps the new feature active; `off` disables both recording and misfire detection for users on shared machines, regulated codebases, or any workflow where persisting prompt previews is unwanted. Documented in `docs/customization.md`. Both env var `OMC_CLASSIFIER_TELEMETRY` and conf key `classifier_telemetry=on|off` honor the standard env-beats-conf precedence.

### Fixed (excellence pass — post-review polish)

- **Misfire detection staleness** — `detect_classifier_misfire` now skips annotation when the prior telemetry row is more than 15 minutes old (`now - prior_ts >= 900`). A user walking away and returning with "do it" should not retroactively tag a block that fired hours ago as a misfire. Window mirrors the 15-minute post-compact-bias decay in `prompt-intent-router.sh` for consistency.
- **`uninstall.sh` removes the post-merge hook and `.install-stamp`** — symmetric to `install.sh --git-hooks` / install-stamp-on-install. Reads `repo_path` from `oh-my-claude.conf` *before* that conf is itself removed, then deletes `<repo>/.git/hooks/post-merge` only when it carries the `# oh-my-claude post-merge auto-sync` signature. Foreign hooks at the same path are preserved untouched.
- **Stop-guard on-demand project-test detection** — when `project_test_cmd` is not yet in state (first missing-verify block before any verification has run), stop-guard now runs `detect_project_test_command "."` and writes the result back to state. Without this, the block-1 verbose message fell through to the generic "run the smallest meaningful validation available" text instead of naming the project's test entrypoint.
- **Regex-injection guard in `verification_matches_project_test_command`** — the bash-family regex match previously interpolated the captured directory into a second ERE without escaping, so a `project_test_cmd` of `bash t.sts/foo.sh` would over-match `bash txsts/other.sh` (the `.` became any-char). Now escapes `.` via bash parameter expansion and rejects directories containing bracket-class chars or `..` path-traversal segments.
- **Taskfile test-task false positive** — the Taskfile detector previously matched any indented `test:` line anywhere in the file, so a Taskfile with `vars: test:` or `deps: - test` returned `task test` for projects whose actual test task had a different name. Now an `awk` one-pass scan requires a zero-indent `tasks:` line followed by an indented `test:` key within the block before the next zero-indent key.
- **`grep -c || echo 0` double-emit** — `show-status.sh --summary` and `--classifier` used `"$(grep -c ... || echo 0)"`, which on an existing-but-no-match file concatenated `"0\n0"` and broke `-gt 0` arithmetic under `set -euo pipefail`. Replaced with `"$({ grep -c ... || true; } | tail -n1)"` so a single integer always comes back.

### Testing

- `tests/test-common-utilities.sh` grows from 338 to 349 assertions (+11 sections, ~40 new checks): `detect_project_test_command` tiers (justfile, Taskfile, bash orchestrator, alphabetical `tests/test-*.sh`, precedence-vs-language-manifest), Taskfile false-positive guards (`vars: test:`, `deps: - test`), `verification_matches_project_test_command` bash-family match (positive, sibling, cross-dir, regex-injection `.` in ptc, path-traversal), and classifier telemetry (misfire recorded on affirmation, negation suppression, no-block-no-misfire, prior-execution-no-false-positive, staleness guard, opt-out both recording and detection).
- `tests/test-e2e-hook-sequence.sh` seq-D assertion relaxed from `validation` to the `validat` stem — the block-1 verbose message now reads "to validate" when `detect_project_test_command` fills `project_test_cmd` on demand, so the assertion tracks both phrasings.

### Reliability hardening

- **Closed lock gaps on the PostToolUse hot path.** `mark-edit.sh` wrapped both doc and code `write_state_batch` calls in `with_state_lock_batch`; `record-advisory-verification.sh` wrapped the bare `write_state "last_advisory_verify_ts"` and stall-counter reset in `with_state_lock`. The two writers directly share `stop_guard_blocks` and `session_handoff_blocks`, and `write_state_batch`'s full-JSON rewrite pattern also means either writer could clobber the other's updates to adjacent keys (`dimension_guard_blocks` from reviewer, `advisory_guard_blocks` + `stall_counter` from mark-edit) by preserving them from a stale snapshot. Symptoms were not user-visible as misbehavior yet, but future reviewer fan-outs (parallel agents) would surface them as "gate fires when it shouldn't" or stale counters.
- **Default-on anomaly logging via `log_anomaly`.** `common.sh` gains a second logging channel alongside the debug-gated `log_hook`. Anomalies — corrupt state, invalid session IDs, lock-exhaustion warnings, defect-patterns corruption — now write to `hooks.log` unconditionally with an `[anomaly]` tag, capped at the same 2000/1500 rotation as the debug log. Previously the first bug report on a user's machine required "please enable `hook_debug=true` and reproduce," which was a dead-end when the anomaly was already past. `log_hook` stays behind `hook_debug=true` for verbose per-hook traces.
- **`omc-repro.sh` bundle script.** New top-level script at `bundle/dot-claude/omc-repro.sh` (installed to `~/.claude/omc-repro.sh`) packages a session's state into a shareable tarball: `session_state.json`, `classifier_telemetry.jsonl`, `recent_prompts.jsonl`, edited-files log, subagent summaries, pending-agents log, and the last 200 lines of `hooks.log`, plus a manifest with oh-my-claude version, OS, shell, and jq versions. Redaction contract applies uniformly: every field that holds user-originated prompt or assistant-message text (`last_user_prompt`, `last_assistant_message`, `current_objective`, `last_meta_request` in session state; `prompt_preview` in classifier telemetry; `text` in recent_prompts) is truncated to 80 chars (configurable via `OMC_REPRO_REDACT_CHARS`). Redaction uses per-row `try/catch` so a malformed JSONL row is dropped rather than copied through as plaintext; on jq failure the script emits `{}` rather than falling back to the unredacted original. Run `bash ~/.claude/omc-repro.sh` to bundle the most recent session, `bash ~/.claude/omc-repro.sh <session-id>` for a specific one, `bash ~/.claude/omc-repro.sh --list` to see recent sessions newest-first. Registered in both `verify.sh::required_paths` and `uninstall.sh::STANDALONE_FILES` per the parallel-install-list rule.

### DX polish

- **`--bypass-permissions` surfaced before install commits, not after.** `install.sh` now prints a 3-line tip before any filesystem changes explaining what `--bypass-permissions` does and letting interactive users Ctrl-C to re-run with the flag (2-second pause, skipped in CI / non-TTY). Previously the tip appeared *after* the install completed, which meant power users ran the installer twice on their first day. `README.md` quick-start also now shows `install.sh --bypass-permissions` as the recommended command with a one-sentence explanation, and keeps the plain `install.sh` variant as a clearly-labeled alternative.
- **Skill list drift fixed across three sources of truth.** `README.md` adds `frontend-design` and `ulw-demo` (was missing 2 skills); `bundle/dot-claude/skills/skills/SKILL.md` adds `frontend-design` (was missing 1); `bundle/dot-claude/quality-pack/memory/skills.md` adds `/council` (was missing the council entry). All three now enumerate the 16 user-invocable skills. `CLAUDE.md` gains a new rule that makes this three-way sync explicit for future skill additions.

### Testing

- `tests/test-concurrency.sh` **new** — stress tests for `with_state_lock`, `with_state_lock_batch`, mixed single-plus-batch writers, and the `with_metrics_lock` path around `record_agent_metric`. Forks 20-30 concurrent writers and asserts no lost updates. Regressions in the lock primitive would surface as dropped counters, which are invisible under serial test workloads — only a forked-writer test catches them.
- `tests/test-post-merge-hook.sh` **new** — covers `install.sh --git-hooks` end-to-end by extracting the `install_git_hooks` function and calling it against a disposable fake repo created via `git init`. Seven cases: signed-hook install, foreign-hook preservation, idempotent re-run, uninstall removal clause (drops signed, keeps foreign), no-manifest no-op, **positive content-drift detection** (bundle file newer than install-stamp → banner fires), and **positive file-set-drift detection** (manifest diverges from current bundle → banner fires).

### Fixed (reviewer-pass polish)

- **omc-repro.sh privacy contract corrected.** The initial cut redacted only `classifier_telemetry.jsonl`'s `prompt_preview` field while copying `session_state.json` and `recent_prompts.jsonl` verbatim — those files carry `last_user_prompt`, `last_assistant_message`, `current_objective`, `last_meta_request`, and per-row `.text` in full. The script now redacts all six fields uniformly to 80 chars, removes the fallback-copy-on-jq-failure path (previously `jq ... || cp original`, which leaked on a single malformed row), and switches to a `try/catch` per-row filter so bad rows are dropped instead of copied through. The user-facing closing message correctly names the three redacted files.
- **`_AGENT_METRICS_FILE`, `_AGENT_METRICS_LOCK`, `_DEFECT_PATTERNS_FILE`, `_DEFECT_PATTERNS_LOCK` override-safe.** Previously these were unconditional assignments at `common.sh` source time, so a caller setting them before `source common.sh` would see them clobbered back to the production paths — harmless today but a latent footgun if any future test/caller set them pre-source. Now all four use `${VAR:-default}` so pre-set values survive.
- **install.sh banner only prints on interactive TTYs.** The pre-install `--bypass-permissions` tip is now gated on `[[ -t 0 ]] && [[ "${CI:-}" != "1" ]]` — curl-pipe-bash and CI flows skip it entirely rather than seeing a misleading "press Ctrl-C now" they can't act on. Phrasing tightened to "cancel now (Ctrl-C)" to match.

### Fixed (excellence-pass polish)

- **`omc-repro.sh` manifest includes hook-log tag counts.** Bundle recipients now see `anomalies: N / debug: M` counts from the bundled `hooks.log.tail` at the top of `manifest.txt`, so triage starts from "how many anomalies?" rather than "let me `cat` the tail." Uses the `grep -c || true | tail -n1` form to avoid the pipefail double-emit footgun already fixed elsewhere.
- **`docs/faq.md` documents `[anomaly]` logging and `omc-repro.sh`.** The "How do I debug hook execution?" entry now leads with `grep '\[anomaly\]'` (always-on channel) before mentioning the opt-in `hook_debug=true`. A new "How do I report a bug?" entry documents the `omc-repro.sh` bundle flow, including `--list` / `<session-id>` variants and the `OMC_REPRO_REDACT_CHARS` override.
- **`docs/customization.md` documents `--git-hooks`, `--no-ios`, and `omc-repro`.** A new "Other install flags" section explains `--git-hooks` (opt-in post-merge auto-sync with `OMC_AUTO_INSTALL=1` for CI) and `--no-ios`. A new "Bug reports with omc-repro" section documents the bundle flow, redaction contract, and `OMC_REPRO_REDACT_CHARS` override. The env-var override list under "Configurable thresholds" now names `OMC_REPRO_REDACT_CHARS` too.
- **CHANGELOG lock-bullet precision.** The initial "share `stop_guard_blocks` / `session_handoff_blocks` / `dimension_guard_blocks`" wording overstated the direct key overlap between mark-edit and the reviewer — only the first two are literally shared; `dimension_guard_blocks` is reviewer-only but still at risk via `write_state_batch`'s full-JSON rewrite pattern that preserves stale snapshots. Bullet rewritten to call out both the shared pair and the adjacent-key stale-snapshot risk.
- **Minor polish:** removed a dangling `F2-style` internal-review artifact from the `omc-repro.sh` header comment; added a `shellcheck disable=SC2016` for the intentional-single-quotes-with-literal-backticks printf line.

### Testing

- **Zero regressions across 1,574 total tests** (11 shell suites + `test_statusline.py`). New suites contribute 25 assertions; prior 1,549 all pass.

## [1.8.1] - 2026-04-18

### Fixed

- **Mixed-intent release prompts route as execution, not advisory** — the classifier previously scored prompts by their *head* only, so a release prompt phrased per the CLAUDE.md checklist ("Please comprehensively evaluate each point… after all these, commit the changes and tag and release.") was tagged `advisory` because of the `Please … evaluate` opening. The PreTool guard then blocked the user's own explicit commit/tag/push sequence — ironically, the CLAUDE.md release checklist prescribes this exact phrasing pattern. `is_imperative_request` now has a tail-position branch that matches a sentence-boundary (`.`, `,`, `?`, `\n`) followed by an optional transition word (`then|now|finally|lastly|also|afterwards|next`) followed by a narrow destructive-execution verb (`commit|push|tag|release|deploy|merge|ship|publish`) followed by an object marker (`the|a|an|all|these|this|that|those|to|origin|upstream|v<N>|it|them|changes|and`). The verb list is deliberately narrow — verbs that are unambiguously authoritative-execution when used imperatively. Past-tense mentions (`we pushed yesterday`), noun uses (`the commit message`, `the push date`), and ambiguous safer verbs (`run`, `make`) are not matched. Originating incident: the v1.8.0 release session where the original developer-note prompt was misclassified and the user had to send a fresh imperative follow-up to authorize the release.
- **Shell-native project test scripts satisfy the verification-confidence gate** — `verification_has_framework_keyword` now recognizes shell-script invocations whose path or filename marks them as test scripts: `(bash|sh|./) … (tests?/|\btest[-_]|_test\b) … .sh`. Matches `bash tests/test-foo.sh`, `bash test-runner.sh`, `./test_helper.sh`, `bash path/to/tests/x.sh`. Without this, pure-bash projects (like oh-my-claude itself) that have no `package.json` / `Cargo.toml` / etc. to advertise a canonical test command scored 30 on their own test runs — below the default threshold of 40 — even when the test output printed `Results: N passed`. The v1.8.0 release session hit this ironically in its own stop-guard: `bash tests/test-install-artifacts.sh` with 20 assertions passed was rejected as low-confidence. `bash example.sh`, `cat tests/foo.sh`, and non-`.sh` invocations are correctly not matched (narrowed by `.sh` terminus, bash/sh/`./` prefix, and word-boundary `test` to exclude `testing`/`testdata`).

### Testing

- `tests/test-intent-classification.sh` grown from 374 to 422 assertions (+48). New *Tail-position imperative (mixed advisory + execution)* section covers the original failing prompt shape, transition-word forms (`Then push`, `Now commit`, `Finally release`, `Also commit`, `Afterwards deploy and merge`, `Next commit`), end-to-end `classify_task_intent` parity, and past-tense / noun-use negatives. New *Shell test script recognition in framework_keyword* section covers 9 positive forms (`bash tests/*.sh`, `bash test-*.sh`, `bash test_*.sh`, `./tests/*.sh`, `./test-*.sh`, absolute-path forms, `sh tests/*.sh`, `bash *_test.sh`) and 7 original negatives plus 5 reviewer-found false-positive negatives (`bash contests/foo.sh`, `bash latests/foo.sh`, `bash greatestsmod/foo.sh`, `bash latest-contest.sh`, `bash contest_foo.sh`), plus end-to-end `score_verification_confidence` assertion that the v1.8.0-failing case now scores ≥ 40. New *Release-action polite imperatives* section covers 10 positive forms (`Please push/commit/tag/release/ship/publish/merge …`, `Could you tag … and push?`, `Can you publish …?`, `Would you please ship …?`).
- **Zero regressions:** 1,524 total tests passing (all 10 suites).

### Review refinements

The quality-reviewer agent flagged two false-positive / false-negative edges after the initial 1.8.1 fix:

- **`tests?/` without word boundary false-positived on `contests/`, `latests/`, `greatestsmod/` substrings.** Tightened the shell-test regex from `(tests?/|\btest[-_]|_test\b)` to `(\btests?/|\btest[-_]|_test\b)`. The `\b` before `tests?/` forces a non-word→word transition so `/tests/` (slash → word) and ` tests/` (space → word) match but `contests/` (n → t) does not. Added 5 negative regression tests.
- **Single-clause polite asks like `Please push the changes.` or `Could you tag v2.0?` were not caught by `is_imperative_request`.** The tail-imperative branch requires a sentence boundary, and the Please/Can-you branches did not list release-action verbs. Added `commit|push|tag|release|ship|publish|merge` to both branches so single-clause polite asks now classify imperative directly, without having to rely on the default-execution fallback in `classify_task_intent`. Added 12 positive regression tests.

## [1.8.0] - 2026-04-18

### Added

- **Commit-distance stale-install indicator** — the statusline now surfaces *unreleased-commits* drift in addition to tag drift. `install.sh` records `installed_sha` (40-char `git rev-parse HEAD`) alongside `installed_version` in `oh-my-claude.conf` when the install source is a git worktree. `statusline.py`'s `installation_drift()` returns a dict: `{"version": "X"}` for tag-ahead drift, `{"version": "X", "commits": N}` when VERSION matches but HEAD is N commits past `installed_sha` (computed via `git rev-list --count installed_sha..HEAD` with a 2s timeout). Renders as `↑v1.7.1 (+3)`. Closes the gap where a user would `git pull` two unreleased commits onto a tagged release and the old string-based indicator reported "in sync" while the live install lagged. Fail-closed on unreachable SHAs (rebased/amended history) — no misleading noise for repo maintainers whose main branch rewrites frequently. The `installed_sha` key is *omitted* from conf (not stored as an empty value) when the install source is not a git worktree, and any stale key from a previous worktree install is cleaned up on re-install.
- **Orphan file detection via install manifest** — `rsync -a` preserves legacy files when the bundle renames or removes a script (no `--delete` flag because it would wipe user-created content). `install.sh` now snapshots the bundle's sorted relative-path list to `~/.claude/quality-pack/state/installed-manifest.txt` on each install and compares the *prior* manifest against the *new* bundle via `LC_ALL=C comm -23`. Files that shipped in the previous release but no longer exist in the current bundle are reported under an `Orphans:` header in the post-install summary, with a reinstall hint (`bash uninstall.sh && bash install.sh`) for full cleanup. Locale discipline (`LC_ALL=C` on both the manifest build and the comparison) is enforced so users who change `LANG`/`LC_ALL` between installs — notoriously common in CI jobs — do not see spurious orphan warnings from locale-dependent sort order.
- **`.install-stamp` at install root** — `touch ~/.claude/.install-stamp` runs on every install, giving a reliable mtime reference for "what landed in this install" diffs. `rsync -a` preserves the bundle's source mtimes rather than setting them to install time, so without an explicit stamp `find -newer` queries could not distinguish "touched by this install" from "cloned at this time". BSD/GNU-portable (`touch` with no flags). Documented in `docs/faq.md` under *How do I see what the last install actually changed?* and in `docs/architecture.md` under *Install-time artifacts*.
- **Tightened `harness_health()` in statusline** — the `[H:ok]` indicator now lights only when the newest session directory's `session_state.json` mtime is within the 5-minute window. Previously `hooks.log` (a global file touched by *any* hook in *any* project) and `.ulw_active` were both acceptable triggers, which produced false-positive `[H:ok]` displays when a dormant session's tail-end hook had fired minutes ago. State writes are per-session, so a recent mtime on `session_state.json` is a real "this install is being used right now" signal.
- **Verbose-first / terse-repeat coaching in `pretool-intent-guard.sh`** — the first block of a session emits the full 9-line "What to do instead" coaching text; blocks 2+ compress to a 2-line reminder (`Blocked (advisory, block #N): …`) so heavy blocking (e.g. a looping attempt to commit) no longer floods the conversation. Mirrors the block-1-verbose / block-2+-terse pattern already used by `stop-guard.sh`. The post-increment counter is captured *inside* the `with_state_lock` call (via a stdout echo from `_increment_pretool_blocks`), closing a race where a parallel tool_use block could make the first-ever hook observe another hook's increment and silently downgrade its own coaching message to terse.
- **Intent Guards section in `/ulw-status`** — `show-status.sh` moves `Advisory guards` and `PreTool intent blocks` from the generic `--- Counters ---` section into a dedicated `--- Intent Guards ---` stanza so intent-guard firing rates are easier to scan as the family grows.
- **Prominent restart hint in `verify.sh` and `install.sh`** — both post-install messages now carry a bold (`\033[1m…\033[0m`) line calling out that upgraded installs require restarting Claude Code to load the new hooks. Closes a UX gap where users would re-run `install.sh` after `git pull` and assume the change took effect immediately, when in fact already-running sessions keep the previous hook bindings until restart.
- **Shell-only verification-threshold recipe** — `docs/customization.md` gains a *Recipe: shell-only / lint-as-tests projects* section explaining how to drop `verify_confidence_threshold=30` into a project-level `.claude/oh-my-claude.conf` so pure-bash projects where `shellcheck`/`bash -n` are the only automated signals can satisfy the quality gate without weakening verification globally. Includes a `custom_verify_patterns` example for project-specific test wrappers.
- **Auto-memory opt-out guidance** — `docs/faq.md` adds *Why does Claude write files to ~/.claude/projects/*/memory/ after a session?* with three scoped opt-outs: per-session imperative ("do not save anything to memory this session"), per-project `.claude/overrides.md`, and machine-wide `omc-user/overrides.md`. Explicitly steers users away from deleting the `@auto-memory.md` import (which `install.sh` re-adds) and toward `omc-user/` overrides which survive updates.
- **Known-gap documentation for the PreTool guard** — `docs/compact-intent-preservation.md` gains a *Known coverage gaps* section enumerating three boundary forms the command-line pattern matcher deliberately does not cover (embedded newlines in a single command, process substitution via `$(...)`/`<(...)` , language-runtime wrappers that invoke git without naming the binary) and explains why narrowing them would cost more than it saves.
- **`docs/architecture.md` — Install-time artifacts subsection** — documents `repo_path`, `installed_version`, `installed_sha`, `installed-manifest.txt`, and `.install-stamp` as the four persistent artifacts `install.sh` writes outside the bundle, closing the doc gap between state keys (session-scoped) and install metadata.

### Fixed

- **Race in `pretool-intent-guard.sh` verbose/terse branching** — the block counter was incremented inside `with_state_lock` but the verbose-vs-terse decision was driven by a second `read_state` *outside* the lock. Under parallel Bash tool_use blocks within a single assistant turn, hook A could complete its increment-and-release, hook B could then enter the lock and advance the counter from 1 to 2, and hook A's post-lock read would observe the value 2 — silently downgrading the first coaching message to terse. Fixed by echoing the post-increment value from inside the locked function and capturing via `$(...)`. Regression coverage in `test-e2e-hook-sequence.sh` gap 8s.
- **Orphan detection locale sensitivity** — both the manifest build and the `comm -23` comparison now run under `LC_ALL=C` so the sort key is stable across install runs regardless of the user's locale. Without this, users toggling `LANG=en_US.UTF-8` ↔ `LANG=C` between installs (common in CI) would have seen false orphan warnings.
- **Empty `installed_sha=` line in conf** — a previous revision wrote `set_conf "installed_sha" ""` when the install source was not a git worktree, leaving an ambiguous empty-value line in `oh-my-claude.conf` that future code could misinterpret. The installer now removes the key entirely in that case, so readers that distinguish "key absent" from "key present but empty" see consistent semantics.

### Changed

- **`statusline.py installation_drift()` return shape** — changed from `str | None` to `dict | None` (`{"version": "X"}` or `{"version": "X", "commits": N}`). The render path in `main()` carries a backward-compat `isinstance(omc_drift, dict)` branch that still handles a bare-string return so an in-place `statusline.py` update before a full reinstall does not crash on a legacy return shape.
- **Serendipity Rule in `core.md`** — closes the adjacent-defect-triage gap in the gold-plating calibration section (shipped mid-cycle, promoted here for release traceability). Tells Claude to fix verified adjacent defects discovered mid-task when all three conditions hold: **verified** (reproduced or same-root-cause analogue, not theoretical), **same code path** (file or function already loaded for the main task), and **bounded fix** (no separate investigation, no new test scaffolding, no substantial diff expansion). All three → fix in-session under a `Serendipity:` summary line. One+ fails but defect is verified → `project_*.md` memory **and** named in the session summary as a deferred risk. The existing "no future-session handoffs" rule now cross-references it.
    - *Originating case:* an iOS session deferred a verified cursor-jitter guard in the same post-frame window as a just-fixed text-loss bug. Prior rules only addressed *additions* (gold-plating), not adjacent-defect triage.
- **Reviewer coverage of the Serendipity Rule** — `quality-reviewer.md` gains priority #9 and `excellence-reviewer.md` gains axis #5. Both cite `core.md` as the single source of truth for the three conditions (prevents criteria drift) and flag two patterns: (a) should-have-fixed deferrals where all three conditions held yet were skipped; (b) verified-but-deferred defects dropped into a memory without being named in the session summary as a deferred risk. Unverified/theoretical/cross-module deferrals remain correctly deferred.

### Testing

- **`tests/test-install-artifacts.sh`** — new file, 20 assertions covering SHA persistence (40-char hex matcher), manifest creation + core-file presence, orphan detection (fake-orphan injection + post-install manifest refresh), install-stamp existence + mtime refresh across re-installs, empty-`installed_sha` cleanup when source is not a git worktree (simulated by temporarily moving `.git` aside), and locale-safe re-install parity (runs install under `LC_ALL=C` then under a UTF-8 locale and asserts no spurious orphan warnings).
- **`tests/test_statusline.py`** — 12 new assertions across `TestInstallationDriftCommitDistance` (no-SHA returns None, SHA matches HEAD returns None, HEAD ahead by N returns `{"version", "commits": N}`, VERSION-ahead short-circuits the SHA check, unreachable SHA fails closed, end-to-end render includes `(+N)`) and `TestHarnessHealth` (missing state root, no sessions, newest-session-fresh returns "active", newest-session-stale returns None, stale hooks.log alone does NOT trigger — the main bug-fix, newest-session mtime drives the decision not older-but-fresh). Updated existing drift tests to assert the new dict return shape. 82 total, all passing.
- **`tests/test-e2e-hook-sequence.sh`** — gap 8s covers verbose-first / terse-repeat behavior in `pretool-intent-guard.sh`: first block contains the full "What to do instead:" coaching text with (a) (b) (c) enumerated options; blocks 2 and 3 omit those labels and include `block #N`; counter advances correctly across all three. 326 total, all passing.
- **Zero regressions across all suites:** e2e 326, intent-classification 374, quality-gates 99, stall-detection 15, settings-merge 166, uninstall-merge 36, common-utilities 324, session-resume 34, install-artifacts 20, statusline 82. **Total: 1,476 tests passing.**

## [1.7.1] - 2026-04-17

### Added

- **Intent-aware compact continuity (advisory-compact regression fix)** — the compact handoff and a new PreToolUse guard now cooperate to preserve non-execution intent across compact boundaries. Previously, when a compact fired mid-response during an `advisory`, `session_management`, or `checkpoint` prompt, `session-start-compact-handoff.sh` unconditionally injected the "keep momentum high" ULW directive; the model read that as execution permission and could push unauthorized commits. The 2026-04-17 incident where four unauthorized commits landed on a sibling landing-page repo is the originating case (see `feedback_advisory_means_no_edits` memory).
  - **Directive layer:** `session-start-compact-handoff.sh` now reads `task_intent` and `last_meta_request`. When intent is non-execution it REPLACES the momentum directive with a guard directive that forbids destructive git/gh operations and inlines the original meta-request (up to 500 chars) so the post-compact thread retains the opinion-ask framing instead of re-inferring intent from a lossy summary.
  - **Enforcement layer:** new `pretool-intent-guard.sh` PreToolUse hook on `Bash`. When ULW is active and `task_intent` is advisory/session-management/checkpoint, it denies destructive git/gh commands — porcelain (`commit`, `push`, `revert`, `reset --hard`, `rebase`, `cherry-pick`, `tag`, `merge`, `am`, `apply`), branch/ref rewriting (`branch -D|-M|-C|--delete|--force`, `switch -C|--force`, `checkout -B|--force`, `clean -f|--force`), plumbing (`update-ref`, `symbolic-ref`, `fast-import`, `filter-branch`, `replace`), and `gh pr|release|issue create|merge|edit|close|delete|reopen|comment`. The path anchor accepts an optional prefix so `/usr/bin/git commit` and `sudo git push` are caught. The guard normalizes git top-level flags before matching, so configured-override bypasses are caught in both `--flag=value` and `--flag value` forms (`git -c commit.gpgsign=false commit`, `git --no-pager commit`, `git --git-dir=/path commit`, `git --git-dir /path commit`, `git --work-tree /tmp commit`, `git --exec-path /usr/libexec commit`, `git --namespace foo commit`, `git --super-prefix sub/ commit`, `git --attr-source HEAD commit`, `git -C /tmp commit`). An allow-list lets recovery and dry-run forms of destructive verbs (`rebase|merge|cherry-pick|revert|am --abort|--continue|--skip|--quit`, `push|commit --dry-run|-n`, `tag -l|--list`) pass through so the model can unstick a mid-operation working tree under advisory intent. Compound commands split on `&&`/`||`/`;`/`|` and each segment is evaluated independently, so `git rebase --abort && git push --force` still denies on the push. Read-only ops (`status`, `log`, `diff`, `show`, `branch` list form, `merge-base`, `commit-tree`) pass through. Execution/continuation intent passes through for all ops. Counter updates use `with_state_lock` to survive parallel tool-use blocks in one assistant turn. The denial reason tells the model to deliver the assessment and wait for an imperative-framed follow-up prompt that the classifier will reclassify as execution.
  - **Configurable kill-switch:** `OMC_PRETOOL_INTENT_GUARD` env var and `pretool_intent_guard=true|false` conf key (default `true`) — users who want to rely on the directive layer alone (e.g. if the advisory classifier over-fires for their workflow) can disable enforcement without editing `settings.json`. Documented in `docs/customization.md`.
  - **Status + deactivation integration:** `/ulw-status` surfaces `PreTool intent blocks: <n>` so users can see the guard's firing rate; `ulw-deactivate.sh` clears `pretool_intent_blocks` alongside the other compact-continuity keys so `/ulw-off` does not leak counter state into a later session.
  - **New state key:** `pretool_intent_blocks` (counter) — documented in `docs/architecture.md`. Does not share the counter with `advisory_guard_blocks`, which still tracks the separate advisory-inspection gate in `stop-guard.sh`.
  - **Post-mortem:** `docs/compact-intent-preservation.md` captures the incident, the root-cause framing (intent state is UserPromptSubmit-scoped but needs to be compact-boundary-scoped), the two-layer design rationale, and what was considered-and-rejected (cwd-drift block, Edit/Write guard, intent-preservation on post-compact bias).
  - **Regression tests:** `test-e2e-hook-sequence.sh` gaps 8a–8r cover (a) advisory+compact emits the guard directive with meta-request inlined and suppresses the momentum line, (b) session_management and checkpoint trigger the same guard, (c) execution intent still gets momentum (negative regression), (d) the guard blocks every destructive subcommand including `/usr/bin/git` absolute-path bypasses and branch/ref rewriting flag forms, (e) 25 allow-list negative assertions for read-only ops, (f) bails when the `.ulw_active` sentinel or kill-switch is absent, (g) non-Bash tool passes through, (h) post-block release path — a fresh execution-framed prompt reclassifies intent and unblocks the next commit, (i) `/ulw-off` clears the counter, (p) flag-injection bypass attempts (`git -c`, `git --no-pager`, `git --git-dir=`, `git -C`, stacked `-c`) all block, (q) recovery/dry-run/list variants pass through without incrementing the counter, (r) compound commands deny on destructive segments even when paired with allow-listed ones.
- **Stale-install indicator on the statusline** — surfaces the "I pulled but forgot to re-run `install.sh`" case. When `${repo_path}/VERSION` is newer than the bundle's recorded `installed_version`, the statusline appends a yellow `↑v<repo>` next to the dim `v<installed>` tag. Local-only — zero network calls. Comparison is semver-aware so a deliberate downgrade (e.g. local bisect) does not trigger; non-numeric versions fall back to plain inequality. Requires `repo_path` in the conf, which `install.sh` writes on every install. Disable via `installation_drift_check=false` in `oh-my-claude.conf` or `OMC_INSTALLATION_DRIFT_CHECK=false`. Covered in `docs/customization.md`, `docs/faq.md`, and the README Updating section.
- **Upgrade path discoverability** — README Quick start now has a visible `Upgrading from a prior release?` block stating that after `git pull` users must re-run `bash install.sh`; the previous discovery path required scrolling to the FAQ. `verify.sh` post-install messaging gained the same hint so a user re-running verification after a stale install sees the next step inline. Three new FAQ entries cover (a) diagnosing a stale live install, (b) interpreting a truncated subagent result and the re-dispatch pattern, (c) resetting `defect-patterns.json` and `agent-metrics.json` to zero counts after the v1.7.0 classifier rewrite reduced false-positive defect classifications.
- **Right-size agent prompts rule** — `core.md` now names the agent-output-truncation symptom (trailing colon, no structured report) and prescribes the fix (narrower prompts with explicit output-size caps, or multiple focused agents in parallel). Captures the lesson from a session-level reflection where one agent prompt asked an agent to cover 8+ check categories across 10+ files, forcing 43 tool calls before synthesis and exhausting the agent's context mid-generation.

### Fixed

- **`last_verify_method` state-key description** in `docs/architecture.md` previously claimed the values were `bash` or `mcp`. The actual writers produce one of `project_test_command`, `framework_keyword`, `output_signal`, `builtin_verification` (Bash path) or `mcp_<check_type>` (MCP path). Description rewritten to list all five real values.

## [1.7.0] - 2026-04-16

### Added

- **`quality-pack/memory/auto-memory.md`** — new canonical memory file documenting the session-stop and compact-boundary memory-sweep behavior. Loaded for every user via the bundle CLAUDE.md import chain. Replaces a user-override-level rule that was previously ad-hoc per install.
- **Classification line on non-execution hook branches** — continuation, advisory, session-management, and checkpoint injections now surface `**Domain:** … | **Intent:** …` the same way the execution branch does, so users can verify routing regardless of which branch fired. Intent display is normalized (underscore → hyphen) via a shared `display_intent` helper.
- **`compact.md` memory sweep section** — instructs Claude to capture auto-memory candidates at compact boundaries, the highest-cost moment for session forgetting. Cross-references `auto-memory.md`.
- **`docs/prompts.md` autonomy section** — user-facing documentation of the 5-case pause list Claude uses in ulw mode, with a pointer to `core.md` as the canonical source.
- **`session_outcome` state key** — stop-guard records whether the session `completed` (all gates satisfied), was `exhausted` (guard caps reached), or went `abandoned` (TTL-swept without a completed stop). Value is carried into `session_summary.jsonl` for cross-session analytics. Documented in `docs/architecture.md`.
- **Dimension progress checklist in review-coverage block messages** — when the gate blocks on complex tasks, the block message now shows per-dimension status as `[done]` / `[NEXT] <dim> -> run <reviewer>` / `[    ]` with an `N/M dimensions` counter so the agent knows exactly what's left instead of guessing the next reviewer.
- **Council evaluation detection widened** — `is_council_evaluation_request` now accepts project-level nouns (extension, site, website, platform, library, package, plugin, framework) with compound-noun exclusions, and Pattern 1 qualifier allows up to 2 intervening adjectives (e.g. "my Chrome extension"). Advisory prompts that trigger council detection receive the council dispatch protocol instead of the narrower "advisory over code" guidance, since council is a superset.
- **Regression tests** — `test-e2e-hook-sequence.sh` tests 7b and 7c cover the defect-classifier narration-prose-must-not-record and structured-finding-still-records paths; `test-intent-classification.sh` gains 128 new test cases across checkpoint, advisory, imperative, council, and regression sections, plus 4 new tests for footer extraction across legacy/new tail markers and mid-sentence footer-phrase preservation.

### Changed

- **ULW prompt surface hardening** — `core.md` now has a concrete 5-case pause enumeration (replacing the vague "external blocker / irreversible / ambiguity" form), a first-class `FORBIDDEN` rule against using third-party library SDKs / framework APIs / HTTP endpoints / version-sensitive CLI flags from memory (with an exempt list for ubiquitous POSIX tools), a "show your work on reviewer findings" rule, an anti-gold-plating calibration test, and a clarified parallel-vs-sequential tool-call anti-pattern.
- **`autowork/SKILL.md` structure** — rule #3 points to `core.md`'s pause list instead of restating it, first-response framing is mapped per intent branch, a 5-row final-mile delivery checklist was added, and the duplicate "show your work" rule was consolidated.
- **`ulw/SKILL.md`** — stripped to a pure alias wrapper; no longer echoes directives that live in autowork or the hook.
- **Coding-domain hook injection rewritten** — split from one ~500-word run-on string into two skimmable stanzas ("Route by task shape" / "Discipline") with librarian-first / context7-when-installed ordering.
- **`opencode-compact.md` response-length clause** — new `## Response length` subsection concretizing the `numeric_length_anchors` "unless the task requires more detail" escape, so ULW summary deliverables are not clipped by the 100-word cap.
- **Intent classifier pipeline rewrite** — `is_checkpoint_request` restructured into a 5-phase architecture (position-independent unambiguous signals → start-of-text phrases → imperative guard → end-of-text patterns with stop-verb context → boundary-scoped ambiguous keywords); `is_imperative_request` gained 38 previously-missing verbs (26 bare, 12 polite-only); `is_advisory_request` tightened standalone `better`, `worth`, `suggest`, `recommend` to require context or derivational form; `is_session_management_request` synced to match. Fixes a misclassification class where audit-style execution prompts were being tagged as checkpoint requests.
- **Guard exhaustion default** — default `OMC_GUARD_EXHAUSTION_MODE` changed from legacy `warn` to canonical `scorecard`. Legacy names are aliased (`warn → scorecard`, `release → silent`, `strict → block`) so explicit user configs continue to work unchanged. See migration note below.

### Fixed

- **Lock correctness across cross-session stores** — `with_metrics_lock` and `with_defect_lock` unified to use the same time-based stale-lock recovery and `acquired`-flag release pattern as `with_state_lock`/`with_skips_lock`. Both now fail closed on exhaustion (return 1 without running the command) instead of proceeding unprotected, closing a race where parallel hook invocations could corrupt `agent-metrics.json` or `defect-patterns.json`. Recording functions gained `|| true` guards so lock exhaustion does not kill the caller under `set -e`.
- **`umask 077` on hook-written files** — `common.sh` now restricts owner-only permissions on all session state, temp files, and logs. Session state contains raw user prompts and assistant messages; this reduces exposure on shared systems.
- **`validate_session_id` called in resume handler** — defense in depth against path traversal when copying state between session directories. Rejects slashes, null bytes, `..`, and non-`[a-zA-Z0-9_.-]{1,128}` session IDs.
- **Uninstall coverage** — `uninstall.sh` now removes `agents/design-reviewer.md` and the `skills/frontend-design/` directory (both shipped in v1.3.0 / v1.3.x but previously leaked on uninstall). `verify.sh` now includes `skills/frontend-design/SKILL.md` and `quality-pack/memory/auto-memory.md` in its required-paths check.
- **Defect-classifier narration noise** — `record-reviewer.sh` no longer falls back to extracting reviewer narration prose when the primary structured-finding regex doesn't match. Previously, intro sentences like "I have a clear picture now. Let me compile my findings…" were being classified by incidental word matches (`test`, `security`), inflating `unknown`, `missing_test`, and `security` defect counts in cross-session telemetry. The primary regex was widened to accept H3/H4 heading-style findings, numbered items with optional bold, bold-labeled bullets, and a broader set of issue keywords.
- **Footer-extraction regression guard** — `extract_skill_primary_task` accepts both the legacy and new ulw skill footers, and each tail marker is line-anchored (`\n` + marker) so a user task body that quotes the footer phrase mid-sentence is preserved intact instead of being truncated.

### Migration notes for existing users

**Stale auto-memory section in `omc-user/overrides.md`.** If you have the old `## Auto-memory on session wrap-up` section in your personal `~/.claude/omc-user/overrides.md` (from a hand-authored setup), you can safely delete that section — the rule now loads canonically from `auto-memory.md`. Your file is not overwritten by `install.sh`, so no automatic migration happens; the duplicate is idempotent but adds prompt noise. Replace that section with the minimal stub:

```markdown
# User Overrides

This file is loaded after oh-my-claude's built-in defaults and is never overwritten by `install.sh`. Add your custom rules, preferences, and behavioral tweaks here.

## Examples

Uncomment and modify any of these to customize your workflow:
```

**Default `OMC_GUARD_EXHAUSTION_MODE` changed from `warn` to `scorecard`.** These are aliases for the same mode, and `scorecard` is the documented canonical name. If your `oh-my-claude.conf` or environment explicitly sets `guard_exhaustion_mode=warn` / `OMC_GUARD_EXHAUSTION_MODE=warn`, nothing changes — legacy names are still accepted. If you rely on the default, gate exhaustion now emits a quality scorecard rather than a bare warning; this is the documented behavior. No action required unless you prefer `silent` (release without output) or `block` (never release).

## [1.6.0] - 2026-04-14

### Added

- **MCP tool verification recognition** — quality gates now recognize browser-based MCP tools (Playwright `browser_snapshot`, `browser_take_screenshot`, `browser_console_messages`, `browser_network_requests`, `browser_evaluate`, `browser_run_code`, and computer-use `screenshot`) as valid verification alongside Bash commands. Base confidence scores are deliberately below the default threshold (40) so passive observations cannot clear the gate alone — verification only passes when output carries assertion/pass-fail signals or when recent edits include UI files (+20 context bonus).
- **MCP failure detection** — `detect_mcp_verification_outcome()` detects failures from MCP tool output: HTTP 401/403/404/500+, JS error types (`TypeError`, `ReferenceError`, etc.), `Error:` prefix patterns, CORS errors, network timeouts, and error page indicators.
- **UI-context-aware scoring** — `record-verification.sh` scans `edited_files.log` for UI file paths (via `is_ui_path()`) and passes a `has_ui_context` flag to `score_mcp_verification_confidence()`. Editing `.tsx`, `.jsx`, `.vue`, `.css`, `.html` etc. enables the +20 context bonus for browser verification.
- **`custom_verify_mcp_tools` config** — pipe-separated glob patterns for additional MCP tools that count as verification. Configurable via `oh-my-claude.conf` or `OMC_CUSTOM_VERIFY_MCP_TOOLS` env var. Custom tools also require a matching PostToolUse hook entry in `settings.json`.
- **PostToolUse hook matcher for MCP tools** — new entry in `settings.patch.json` matching Playwright browser observation tools and `mcp__computer-use__screenshot`.
- **E2e hook tests for MCP verification** — 8 new test sequences in `test-e2e-hook-sequence.sh` covering MCP state recording, failure detection, UI context bonus, passive blocking, computer-use, and `browser_run_code`.
- **Low-confidence gate in test helper** — `run_stop_guard_check()` in `test-quality-gates.sh` now replicates the `verify_low_confidence` gate from the real stop-guard for accurate integration testing.

### Changed

- **Verification confidence scoring** — MCP tool base scores: `browser_dom_check`=25, `browser_visual_check`=20, `browser_console_check`=30, `browser_network_check`=30, `browser_eval_check`=35, `visual_check`=15. All below the default threshold of 40, requiring output signals or UI context to pass.
- **`record-verification.sh` dual-path architecture** — now handles both Bash commands (existing) and MCP tool names. Backward-compatible: empty `tool_name` falls through to Bash path.

## [1.5.0] - 2026-04-14

### Added

- **`/ulw-skip <reason>` command** — single-use gate bypass with logged reason. Registers a skip via `ulw-skip-register.sh` using `with_state_lock_batch`. Records `gate_skip_edit_ts` at registration time; stop-guard validates the edit clock hasn't advanced since registration (new edits automatically invalidate stale skips). Skip reasons logged to `gate-skips.jsonl` with file-level locking for cross-session threshold tuning analysis.
- **Verification confidence gate** — stop-guard now checks `last_verify_confidence` against `OMC_VERIFY_CONFIDENCE_THRESHOLD` (default 40). Lint-only checks like `shellcheck` (score 30) and `bash -n` (score 30) are blocked; project test suites (70+) and framework runs with output signals (50+) pass. Configurable via `oh-my-claude.conf`.
- **Per-project configuration** — `load_conf()` refactored into `_parse_conf_file()` + directory walk-up from `$PWD` looking for `.claude/oh-my-claude.conf`. Project-level values override user-level; env vars override both. Walk capped at 10 levels, skips `$HOME` to avoid double-read.
- **Gate level control** — new `gate_level` config (basic/standard/full). `basic` enables only the quality gate, `standard` adds the excellence gate, `full` (default) enables all gates including review coverage.
- **Pre-sweep session aggregation** — before TTL sweep destroys session data, one summary line per session is written to `session_summary.jsonl` with domain, intent, edit counts, verification confidence, guard blocks, and dispatch count. Enables longitudinal quality analysis.
- **Subagent dispatch counting** — `record-pending-agent.sh` increments `subagent_dispatch_count` in session state. Displayed in `/ulw-status` for cost visibility.
- **Project identity** — `_omc_project_id()` hashes `$PWD` for cross-session data filtering. Added to agent metrics (`last_project_id`) and defect patterns.
- **Schema versioning** — cross-session stores (`agent-metrics.json`, `defect-patterns.json`) now include `_schema_version=2`. All jq consumers filter `_`-prefixed metadata keys via `map(select(.key | startswith("_") | not))`.
- **Runtime health indicator** — `statusline.py` shows `[H:ok]` when the harness is actively intercepting hooks (sentinel or hooks.log touched within 5 minutes) but ULW mode is not displaying.
- **Session start timestamp** — `session_start_ts` recorded on first ULW activation. Enables session duration computation in `/ulw-status`.
- **`jq` runtime guard** — `common.sh` exits gracefully with a message if `jq` is missing, preventing silent hook failures.
- **Security hardening** — `chmod 700` on session directories in `ensure_session_dir()`.
- **Non-coding domain improvements** — writing domain: document-type detection guidance, prose-tool verification patterns (`markdownlint`, `vale`, `textlint`, `alex`, `write-good`). Research domain: source-quality scoring guidance. Operations domain: action-item structure guidance with owner/deadline/done-condition. All three domains gained bigram scoring patterns for stronger classification.
- **E2e regression test** for low-confidence verification path (shellcheck at threshold 40).

### Changed

- **`/ulw` is now the canonical command name** — `autowork` removed from skills table and demoted to "also works" alias. Decision guide and memory files updated.
- **Gate messages use human-readable vocabulary** — `[Dimension gate]` → `[Review coverage]`; raw identifiers like `stress_test` replaced with `describe_dimension()` output (e.g., "stress-test (hidden assumptions, unsafe paths)").
- **Guard exhaustion modes renamed** — `release` → `silent`, `warn` → `scorecard`, `strict` → `block`. Old names accepted via normalization for backward compatibility.
- **README restructured** — Quick Start moved above feature highlights for faster activation. Agent auto-dispatch note added. Demo placeholder for future asciinema recording.
- **Post-install messaging** — `verify.sh` recommends `/ulw-demo` as primary next step with "you don't need to learn agent names" note.
- **`record_agent_metric` now passes actual confidence** — clean verdicts get 80, findings get 60 (previously defaulted to 0, making `avg_confidence` converge to zero).
- **Defect classifier hardened** — word boundaries added to collision-prone patterns. "error" no longer matches everything; "null_check" requires compound context; "missing_test" catches "no unit tests" phrasing.

### Fixed

- **`avg_confidence` was always zero** — `record-reviewer.sh` called `record_agent_metric` with only 2 args; the 3rd (confidence) defaulted to 0. Now passes 80/60 based on verdict.
- **Cross-session jq consumers crashed on `_schema_version` key** — `to_entries` produced `{key:"_schema_version", value:2}` where `.value.last_seen_ts` on a number caused silent jq errors. All `to_entries` consumers now filter `_`-prefixed keys and non-object values.

## [1.4.2] - 2026-04-14

### Fixed

- **`detect_project_profile` operator precedence** — `[[ A ]] || [[ B ]] && cmd` only fired `cmd` on the last alternative due to bash `&&`/`||` grouping. Docker tag required `docker-compose.yaml` specifically; Dockerfile-only and docker-compose.yml-only projects were untagged. Same bug on terraform and ansible lines. Converted all three to `if/then/fi`.
- **Silent data loss in agent metrics and defect pattern writes** — three `jq ... > tmp && mv tmp target || rm -f tmp` chains would silently delete new data if `mv` failed (e.g. full disk). Converted to explicit `if ! mv; then rm; fi`.
- **Integer arithmetic crash on float/null values** — `record_agent_metric` used raw jq output in bash `$((...))`. Floats like `3.7` or `null` from corrupted JSON killed the hook under `set -e`. Added sanitization to truncate floats and default non-numeric values to 0.
- **Lock functions ran commands without holding the lock** — after stale lock recovery in `with_metrics_lock` / `with_defect_lock`, the command could execute unlocked if another process grabbed the lock in the gap. Added `acquired` flag tracking; lock is only released when actually held.
- **SC2155 return-value masking** — `local archive="$(...)"` in `_ensure_valid_defect_patterns` masked the exit code of the command substitution. Split declaration and assignment.
- **Lock release used the same `&&`/`||` anti-pattern** — caught by quality-reviewer: the initial lock fix used `[[ acquired ]] && rm ... || true`, which is the same precedence bug as fix #1. Converted to `if/then/fi`.

### Added

- **Regression tests for all six fixes** — 12 new assertions: `detect_project_profile` with Dockerfile-only, docker-compose.yml-only, terraform-dir-only, main.tf-only, ansible.cfg-only, playbooks-dir-only; `record_agent_metric` basic recording, second invocation, and float-value survival.

## [1.4.1] - 2026-04-14

### Fixed

- **Cross-session watch-list injection was dead code** — `prompt-intent-router.sh` checked `TASK_INTENT == "imperative"` but `classify_task_intent()` returns `"execution"`. Defect patterns were tracked but never surfaced to the model. Fixed to use `is_execution_intent_value()`.
- **Guard exhaustion polluted defect patterns** — `record_defect_pattern "guard_exhaustion"` calls in `stop-guard.sh` recorded operational events as code defects, producing noise in the watch-list. Removed.
- **Design findings classified as "unknown"** — added `design_issues` and `accessibility` categories to `classify_finding_category()` so design-reviewer and accessibility findings are properly tracked across sessions. Expanded `design_issues` regex with actual design-reviewer rubric vocabulary (symmetrical layouts, uniform padding, feature cards, framework defaults, etc.).
- **Performance regex matched "perfectly" as "perf"** — tightened to `perform|\bperf\b` so "perfectly symmetrical layouts" is correctly classified as `design_issues`, not `performance`.
- **Domain scorer motion regex out of sync with `is_ui_request()`** — the `infer_domain()` motion bigrams regex did not support articles ("add an animation"). Synced with `is_ui_request()` so domain classification matches the routing helper.
- **Defect patterns and agent metrics shared a lock** — separated into `_DEFECT_PATTERNS_LOCK` / `with_defect_lock()` to eliminate unnecessary contention.
- **Reviewer reflection enrichment missed `briefing-analyst`** — the substring heuristic only matched `review|critic|metis`. Added `briefing.analyst|oracle` so all reviewer-contract agents get historical pattern injection.

### Added

- **Actionable watch-list injection** — `get_defect_watch_list()` now includes concrete examples from past findings (e.g. `missing_test ×12 (e.g. "no tests for parser")`), not just category names and counts. Stale patterns (>90 days) are filtered out.
- **Reviewer reflection enriched with historical patterns** — `reflect-after-agent.sh` injects the defect watch-list when a reviewer returns, so the main thread cross-references findings against recurring patterns.
- **Defect patterns file validation on read and write paths** — `_ensure_valid_defect_patterns()` detects corrupted `defect-patterns.json`, archives the corrupt file, and resets to `{}`. Called from both write (`record_defect_pattern`) and read (`get_defect_watch_list`, `get_top_defect_patterns`, `/ulw-status`) paths with a per-process cache to avoid redundant checks.
- **Defect patterns in `/ulw-status`** — cross-session defect patterns now displayed with occurrence counts, last example, and 90-day staleness filtering.
- **Test coverage for cross-session learning** — 83 new test assertions covering `classify_finding_category` (including design-reviewer rubric phrases), `is_ui_path`, `is_ui_request`, `record_defect_pattern`, `get_defect_watch_list`, `_ensure_valid_defect_patterns` (including archive creation and read-path recovery), `build_quality_scorecard`, and domain scoring for animation article variants.

## [1.4.0] - 2026-04-14

### Added

- **Concurrent hook safety** — `with_state_lock_batch()` convenience wrapper in `common.sh` for atomic multi-key state writes. All write paths in `record-reviewer.sh`, `reflect-after-agent.sh`, `record-plan.sh`, `record-advisory-verification.sh`, and `record-verification.sh` now wrapped in proper locks.
- **Verification confidence scoring** — `score_verification_confidence()` and `detect_project_test_command()` in `common.sh`. Records confidence level (0-100) and method used. Stop guard now names specific test commands in block messages (e.g., "npm test" instead of generic "verification").
- **Project-context-aware domain inference** — `detect_project_profile()` scans for package.json, Cargo.toml, go.mod, etc. to build a project profile. `infer_domain()` uses profile as tiebreaker (+2 coding, +1 docs) without overriding the protected 40% mixed threshold.
- **Quality scorecard on guard exhaustion** — `build_quality_scorecard()` generates a human-readable scorecard with ✓/✗/– marks for all quality dimensions. Configurable via `guard_exhaustion_mode` in `oh-my-claude.conf` (warn/strict/release, default: warn).
- **Dynamic dimension ordering** — `order_dimensions_by_risk()` prioritizes missing dimensions by risk (stress_test→bug_hunt→code_quality→design_quality→prose→completeness→traceability). UI-heavy projects boost design_quality priority.
- **Smarter stall detection** — `compute_stall_threshold()` scales with file count and plan presence. `compute_progress_score()` (0-100) based on edits/verify/review/dims. High-progress sessions get softer "EXPLORATION CHECK" instead of "STALL DETECTED".
- **Compaction continuity improvements** — pre-compact snapshot now includes structured quality dimension status, verification confidence, and guard state. Post-compact handoff injects dimension status (completed/pending) to prevent redundant reviewer dispatch.
- **Agent performance tracking** — cross-session `agent-metrics.json` tracks invocation counts, clean/findings verdicts, and rolling confidence averages per reviewer type. Visible in `/ulw-status`.
- **Cross-session defect learning** — `defect-patterns.json` tracks defect category frequencies (missing_test, null_check, edge_case, etc.) with recent examples. Top patterns injected into prompts to prime the model for historically frequent defect categories.
- **Enhanced `/ulw-status`** — now shows dimension verdicts (CLEAN/FINDINGS), verification confidence, project profile, guard configuration, and cross-session agent metrics.
- **Dimension verdict tracking** — `dim_<name>_verdict` state keys (CLEAN/FINDINGS) written by `record-reviewer.sh` for all reviewer types, enabling clean-sweep detection and enriched scorecards.
- **Progress score on penultimate block** — quality gate blocks 2+ show a progress score to help the model understand how close it is to completion.

## [1.3.1] - 2026-04-12

### Security

- **Session ID validation** — `validate_session_id()` in `common.sh` rejects path traversal characters (slashes, `..`, spaces, backticks) before any filesystem operation. Prevents crafted session IDs from writing state outside the state directory.
- **`append_limited_state` race fix** — replaced fixed `.tmp` suffix with `mktemp` to prevent silent JSONL corruption when concurrent hooks fire simultaneously.
- **Custom verification pattern validation** — `record-verification.sh` now checks `grep` exit code 2 (invalid regex) before concatenating user-supplied patterns from `oh-my-claude.conf`.

### Fixed

- **State corruption recovery** — `_ensure_valid_state()` detects corrupt `session_state.json`, archives the corrupt file, and resets to `{}`. Prevents the cascade where corrupt JSON silently disables all quality gates.
- **Edit-count race condition** — `mark-edit.sh` now wraps the dedup check and counter increment in `with_state_lock` to prevent lost updates when concurrent PostToolUse hooks fire.
- **Guard exhaustion dimension parsing** — fixed `dims_part` truncation that dropped all dimensions after the first comma (e.g., showed only "stress_test" instead of "stress_test, completeness, prose").
- **Stall detection evasion** — agent dispatch now halves the stall counter instead of resetting to 0, preventing Read-Agent-Read-Agent cycles from evading detection.

### Added

- **Intent classification visibility** — first ULW response now surfaces the detected intent and domain (e.g., "Domain: coding | Intent: execution") so users can verify routing.
- **Human-readable guard exhaustion messages** — raw state variable names (`review=1,verify=1`) translated to readable descriptions ("code review, test verification").
- **Enhanced `/ulw-status`** — new Quality Status section (verification/review as "PENDING"/"passed"/"FAILED"), dimension block counters, edit counts, dimension tick timestamps.
- **28 new verification patterns** — docker, terraform, ansible, helm, kubectl, mvn, maven, dotnet, mix, elixir, ruby, bundle, rake, zig, deno, nix, plus action verbs: validate, verify, plan, apply.
- **Git operation domain keywords** — commit, push, merge, rebase, branch, cherry-pick, stash, tag as weak coding signals in `infer_domain()`.
- **hooks.log rotation** — capped at 2000 lines, truncates to 1500 to prevent unbounded growth when debug mode is left enabled.
- **User-override layer** — `~/.claude/omc-user/` directory for customizations that survive `install.sh` updates. Files in `omc-user/memory/` are loaded after bundle defaults via `@`-references.
- **`/ulw-demo` onboarding skill** — guided first-run experience that walks a new user through a quality gate cycle.
- 27 new tests: session ID validation, state corruption recovery, stall-counter halving, git keyword classification.

### Changed

- Skill count: 14 → 15 (new `/ulw-demo` skill)

## [1.3.0] - 2026-04-12

### Added

**Project Council: multi-role evaluation panel.** A solo developer now gets the cross-functional perspective that a full product team provides through daily friction -- without the team.

- **6 role-lens agents** -- read-only evaluation specialists, each with a sharp non-overlapping mandate:
  - `product-lens` — PM perspective: user needs, feature gaps, prioritization, user journey, competitive context
  - `design-lens` — UX Designer perspective: information architecture, onboarding, accessibility, error states, interaction consistency
  - `security-lens` — Security Engineer perspective: threat model, attack surface, auth/authz, data handling, dependency risks
  - `data-lens` — Data/Analytics perspective: instrumentation coverage, data model quality, measurement strategy, analytics readiness
  - `sre-lens` — SRE perspective: reliability, observability, error handling, scaling readiness, deployment/rollback
  - `growth-lens` — Growth Lead perspective: onboarding friction, activation metrics, retention hooks, messaging quality, distribution readiness

- **`/council` skill** — orchestration skill that inspects the project, selects 3-6 relevant lenses based on project type, dispatches them in parallel, waits for all to return, and synthesizes findings into a single prioritized assessment with critical findings, high-impact improvements, strategic recommendations, cross-perspective tensions, and quick wins.

- **Auto-detection under ULW** — `is_council_evaluation_request()` in `common.sh` detects broad whole-project evaluation prompts ("evaluate my project", "what should I improve", "find blind spots", "comprehensive review") and injects council guidance automatically when ultrawork mode is active. No need to invoke `/council` explicitly.

- **Intent classification tests** — 76 new test cases for council detection: 35 positive cases (whole-project evaluation, holistic qualifiers, improvement questions, blind spots, evaluate-and-plan, plural forms, improvements-to-project) and 41 negative cases (focused requests, narrowing qualifiers, post-noun compounds, subsystem scoping, scoped improve targets, architectural concept narrowing).

### Changed

- Agent count: 23 → 29 (6 new role-lens agents)
- Skill count: 13 → 14 (new `/council` skill)
- `prompt-intent-router.sh` injects `COUNCIL EVALUATION DETECTED` guidance block for matching prompts under ULW execution mode
- `uninstall.sh` updated with all 29 agents (was missing `excellence-reviewer.md`) and all 14 skill directories (was missing `skills`, `ulw-off`, `ulw-status`, `council`)
- `verify.sh` adds `council/SKILL.md` to `required_paths`

### Hardened

- **Pattern 1 post-noun guard**: "evaluate my project manager" no longer triggers council. Project-level words followed by compound-noun indicators (manager, plan, structure, team, etc.) are rejected.
- **`_has_narrow_scope()` helper**: Extracted common narrowing guard into a 4-tier helper function used by patterns 3, 4, and 5:
  - Tier A: preposition + demonstrative + artifact ("in this function")
  - Tier B: bare demonstrative + artifact ("this function")
  - Tier C: preposition + subsystem concept without demonstrative ("in error handling", "about architecture")
  - Tier D: PR abbreviation exact-match ("in this PR")
- **Pattern 5 "improvements to" guard**: "plan for improvements to the login flow" correctly rejected — `improvements to [anything]` is inherently scoped.
- **Expanded artifact list**: Added architectural concepts (architecture, design, handling, layer, logic, workflow, pipeline, infrastructure, deployment, etc.) and VCS terms (commit, branch, migration).
- **PR abbreviation safety**: Replaced `pr` with `pull.?requests?` in the `\w*`-suffixed artifact list to prevent matching "project". Added Tier D exact-match `prs?\b` for the abbreviation.
- **Plural support**: Pattern 1 now matches "evaluate my projects" and "assess our products".
- **`_has_scoped_improve_target()` helper**: Pattern 5 now detects scoped "improve" targets: "review and improve the tests" (scoped) vs "review and improve" (broad). Exempts project-level words: "plan for improvements to the project" correctly triggers council.
- **Extended compound-noun list**: Added documentation, dependencies, configuration, roadmap, backlog, strategy, design, review to the Pattern 1 rejection list.

## [1.2.3] - 2026-04-12

### Added

**Compaction continuity hardening (7 gaps).** Closes gaps in how the harness handles Claude Code context compaction so mid-task auto-compacts and manual `/compact` no longer drop working state.

- **Gap 1 — ULW mode affirmation on post-compact resume.** `session-start-compact-handoff.sh` now re-asserts `workflow_mode=ultrawork` and the active task domain as the first injected directive when the pre-compact session was in ultrawork. Prevents the main thread from drifting back to asking-for-permission behavior after the native compact summary drops the framing.
- **Gap 2 — Post-compact intent classifier bias.** `post-compact-summary.sh` sets a `just_compacted=1` single-use flag with timestamp; `prompt-intent-router.sh` reads it on the next `UserPromptSubmit`, within a 15-minute staleness window, and biases toward preserving the prior objective if the follow-up prompt is short or ambiguous. Prevents "status" / "continue" / "next" from being misclassified as a fresh execution task after compact.
- **Gap 3 — Pending specialist tracking across compact.** New `PreToolUse` hook `record-pending-agent.sh` records every `Agent` tool dispatch to `pending_agents.jsonl`. `record-subagent-summary.sh` now removes the FIFO-oldest matching entry on `SubagentStop`. `pre-compact-snapshot.sh` renders a `## Pending Specialists (In Flight)` section, and `session-start-compact-handoff.sh` emits a "re-dispatch interrupted branches" directive. Line-by-line parsing in the cleanup path is robust against a single malformed JSONL line (no more silent queue freeze).
- **Gap 4 — Pending-review enforcement across compact.** `pre-compact-snapshot.sh` sets `review_pending_at_compact=1` when the last edit clock is newer than the last review clock. `session-start-compact-handoff.sh` injects a hard "MUST run quality-reviewer before the next Stop" directive when the flag is set. `prompt-intent-router.sh` clears the flag on the first post-compact prompt so it does not re-inject indefinitely.
- **Gap 5 — Atomic flush on pre-compact.** `pre-compact-snapshot.sh` now uses `write_state_batch` for the compact-adjacent state keys (`last_compact_trigger`, `last_compact_request_ts`, `review_pending_at_compact`) so a concurrent `SubagentStop` cannot interleave between the trigger write and the timestamp write.
- **Gap 6 — `compact_summary` handling hardening.** `post-compact-summary.sh` emits a visible fallback marker (`"(compact summary not provided by runtime...)"`) when the PostCompact JSON's `.compact_summary` field is empty, logs a warning via `log_hook`, and writes the raw hook JSON to `compact_debug.log` when `HOOK_DEBUG=true` is set. Schema verified verbatim against `code.claude.com/docs/en/hooks`: `.compact_summary` is a documented field in `PostCompact`, not `PreCompact` or `SessionStart`.
- **Gap 7 — Back-to-back compaction race protection.** `pre-compact-snapshot.sh` compares `precompact_snapshot.md` mtime against `last_compact_rehydrate_ts`; if the prior snapshot has not been consumed by a `SessionStart(source=compact)` hook, it is archived as `precompact_snapshot.<mtime>.md` before being overwritten. `compact_race_count` is incremented, and archive retention is capped at 5 files.

### Changed

- **`ulw-deactivate.sh`** now clears the new compact-continuity flags (`just_compacted`, `just_compacted_ts`, `review_pending_at_compact`, `compact_race_count`) and deletes `pending_agents.jsonl` on `/ulw-off`. Without this, a `review_pending_at_compact` flag set by an earlier ultrawork session would re-inject a "MUST run quality-reviewer" directive on a later compact resume, even after the user explicitly turned ULW off.
- **`show-status.sh`** now renders a `--- Compact Continuity ---` section with `last_compact_trigger`, `last_compact_request_ts`, `last_compact_rehydrate_ts`, `compact_race_count`, `review_pending_at_compact`, `just_compacted`, and the pending specialist count. Turns `compact_race_count` from dead telemetry into a visible operator signal.
- **`verify.sh`** hook existence check upgraded from plain substring grep to a jq-scoped query. The previous check would have passed if a hook script had been wired under the wrong event (e.g. `record-pending-agent.sh` under `PostToolUse` instead of `PreToolUse`). Falls back to substring grep when jq is unavailable. Also added `record-pending-agent.sh` to `required_paths`, `hook_scripts`, and `required_hooks` arrays.
- **`config/settings.patch.json`** has a new top-level `PreToolUse` event with matcher `Agent` → `record-pending-agent.sh`.

### Fixed

- **Silent pending-queue corruption on malformed `pending_agents.jsonl`.** The original Gap 3 implementation used `jq --slurp` in the `record-subagent-summary.sh` cleanup path, which aborts with exit 5 on the first non-JSONL line. That silently left the pending queue untouched, so every subsequent `SubagentStop` would hit the same parse error and the queue would freeze permanently. Replaced with a line-by-line parser that tolerates individual bad lines (prints them through unchanged) while still matching and removing the target entry via `.agent_type` field parse.

### Testing

- `tests/test-e2e-hook-sequence.sh` grown from 138 to 150 assertions (+12). New `Compaction hardening:` section covers: Gap 1 ULW affirmation, Gap 2 short-prompt bias + stale flag decay, Gap 3 dispatch/snapshot/clear flow, Gap 3 malformed-JSONL robustness (regression), Gap 3 FIFO-oldest same-type removal, Gap 4 pending-review directive, Gap 4 no-edits negative case, Gap 5 atomic batch write, Gap 6 empty-summary fallback, Gap 7 back-to-back archival, and `/ulw-off` state cleanup.
- `tests/test-settings-merge.sh` updated with `PreToolUse` hook count assertion (fresh install + idempotent), `PreToolUse Agent matcher wired` structural check, and `PreToolUse` added to the cross-implementation structural event list at line 737. Still 160 assertions passing.

### Docs

- **CLAUDE.md / README / VERSION** — hooks inventory updated implicitly via the `required_hooks` table in `verify.sh`; README badge and `VERSION` bumped to `1.2.3`.

## [1.2.2] - 2026-04-11

### Changed

- **Non-reviewer investigative agent `maxTurns` audit.** Extends the v1.2.1 reviewer-floor raise to every subagent returning through `reflect-after-agent.sh:41`, where the 1000-char injection truncation makes subagent-side cap raises zero-cost for parent context. Five agents raised to 30 on deep-investigator parity; three agents left unchanged with rationale.
  - `quality-researcher`: 18 → 30. Deep codebase investigator — reads conventions, API usage, wiring points, commands, relevant files. Current 18 was the lowest of the 8 non-reviewer investigatives and below the new 20 floor entirely. Profile matches the reviewer "read every file + trace callers" investigation pattern that established the 30 floor in 1.2.1.
  - `librarian`: 20 → 30. External docs + source-of-truth reference gathering can legitimately span many pages of official docs, multiple primary sources, and repo-local integration points. Distinguishing repo-local facts from external facts (deliverable #2) requires cross-reference work. Parity with the 1.2.1 reviewer floor.
  - `quality-planner`: 20 → 30. Decision-complete plans require learning facts from the codebase/docs, proposing 2+ candidate approaches with tradeoffs, and specifying a file-by-file or system-by-system execution plan with per-step validation. The "implied scope" deliverable (what a senior practitioner would also deliver) requires deep investigation to spot gaps. Deep investigator profile.
  - `oracle`: 24 → 30. "High-judgment debugger and architecture consultant." The entire job description is deep investigation — diagnose root causes, compare technical options, surface hidden assumptions. Already above the 20 floor but not at the deep-investigator floor. 30 establishes parity.
  - `prometheus`: 24 → 30. Interview-first planning that "inspects the codebase and current constraints before asking questions" and turns vague goals into concrete acceptance criteria. Profile matches `quality-planner` (another deep planner raised to 30 in this audit).
  - `chief-of-staff` (20) left unchanged — no evidence, structuring/distilling work for professional-assistant deliverables (plans, checklists, agendas, response drafts) does not typically require deep codebase investigation. Already at the 20 floor. Will be revisited if future sessions produce truncation evidence.
  - `writing-architect` (20) left unchanged — no evidence, outline/structure/thesis work is primarily reasoning rather than investigation, and reference gathering is delegated to `librarian`. Already at the 20 floor. Revisit on future evidence.
  - `draft-writer` (24) left unchanged — no evidence, drafting is generation rather than investigation. Structure and research are delegated upstream to `writing-architect` and `librarian`; this agent is the terminal prose generator. Already above the 20 floor. Revisit on future evidence.

### Docs

- **Documented the injection-truncated `maxTurns` principle** in `docs/customization.md` at the `maxTurns` bullet. Previously this architectural insight lived only in CHANGELOG release notes (1.2.0, 1.2.1) — future contributors adding new agents or tuning existing caps had to read release history to discover it. The extended bullet now covers (1) the ground-truth citation (`skills/autowork/scripts/reflect-after-agent.sh:41` calls `truncate_chars 1000` when building `finding_context`), (2) the implication (raising `maxTurns` costs subagent compute/API spend but has zero parent-context cost), and (3) a rule of thumb (size `maxTurns` to investigative scope, not parent-context budget; deep investigators 25-30+, quick extractors 12-18, err high when uncertain).

### Fixed

- **Intent-gate misclassification of `/ulw`-in-advice-wrapper prompts.** When a `/ulw` slash command was invoked with a task body that quoted previous-session feedback (containing phrases like `This session's opening prompt` + `worth fixing`), the embedded SM/advisory keywords deep in the prompt tripped `is_session_management_request` / `is_advisory_request` and mis-routed an obvious execution request as session-management or advisory. Live failing example: the v1.2.1 release session's own opening prompt, where the classifier flagged `Please carefully evaluate these comments and then carry on: <embedded /ulw blocks>` as session-management. Three layered fixes in `bundle/dot-claude/skills/autowork/scripts/common.sh`:
  1. **`extract_skill_primary_task`** helper pulls the user's task body out of `/ulw` skill-body expansions (between `Primary task:` and `Follow the \`/autowork\``), so classification operates on the actual task instead of the skill wrapper. Called at the top of `classify_task_intent`. The `Primary task:` marker must be line-anchored (preceded by a newline or at the start of text) to prevent mid-sentence mentions from false-positive-extracting the wrong slice of the prompt — without the line anchor, a user prompt like `Please fix the login bug. Primary task: do the rollout.` would extract `do the rollout.` and flip the classification from `execution` → `advisory`. Regression coverage in `test-intent-classification.sh` (`Mid-sentence false-positive guard` block, 2 assertions).
  2. **`is_session_management_request` imperative override + first-400-char scope.** If the prompt already matches `is_imperative_request` (an explicit top-of-prompt directive), SM returns false — embedded SM keywords can't override a clear imperative. As a secondary guard, the session-keyword regex now only scans the first 400 chars of the prompt; real SM queries state their framing near the top, so embedded/quoted content later in the prompt (e.g., a pasted `/ulw` block referencing "this session") no longer trips routing.
  3. **Imperative detection broadened** with `evaluate`, `plan`, `audit`, `investigate`, `research`, `analyze`/`analyse`, `assess`, `execute`, `document`, `extend`, `raise` across polite (`Can/Could/Would you X`) and `Please X` forms, plus an optional `[a-z]+ly` adverb between `please` and the verb so `Please carefully evaluate` and `Please thoroughly audit` match. `evaluate`/`plan`/`research` are *only* in the polite/please forms, not bare-imperative — they can be nouns ("Research indicates..."), so bare-verb-start classification would false-positive.

### Testing

- `test-intent-classification.sh` grown from 60 to 126 assertions. New blocks:
  - `Adverb imperatives` (4 cases) — `Please carefully/quickly/thoroughly/absolutely <verb>`.
  - `New imperative verbs (polite/please forms)` (15 cases) — each added verb in both `Please X` and `Can/Could/Would you X` form.
  - `Skill body extraction` (4 cases) — direct `extract_skill_primary_task` coverage: no-marker, full expansion, missing-tail, leading-`/ulw`-preserved.
  - `/ulw in advice-wrapper regression` (2 cases) — the exact failing prompt shape (skill-body + embedded item #4) and a plain-text variant.
  - `Genuine SM queries (no imperative front)` (2 cases) — ensures the imperative override doesn't over-fire; real SM queries like `Is it better to continue in a new session?` and `Do you think we should compact this session or push through?` still classify as `session_management`.

## [1.2.1] - 2026-04-11

### Changed

- **Reviewer `maxTurns` raised** based on live truncation evidence from the v1.2.0 session. Because reviewer output is already hard-truncated to 1000 chars by `reflect-after-agent.sh` before injection into the parent context, the `maxTurns` cap affects only the subagent's own investigation budget — raising it has zero parent-context cost. The 1.1.0 rationale for lowering these caps ("to limit context bloat") does not hold once the injection-side truncation is factored in.
  - `quality-reviewer`: 20 → 30. Evidence: truncated mid-polish-check at the new 20 cap on a 10-file review during the v1.2.0 session. 30 provides 50% headroom above the observed 10-file ceiling.
  - `excellence-reviewer`: 18 → 30. Evidence: truncated at 18 on a 4-file merger review during the v1.2.0 session. Matches `quality-reviewer` investigative profile (reads all changed files + callers + tests + compares against the original objective); no defensible asymmetry between the two.
  - `editor-critic`: 12 → 20. Revisits the v1.2.0 decision (which left `editor-critic` at 12 "because prose reviews use fewer tool calls and no truncation was observed there"): that rationale held while there was no contrary evidence, but also nothing affirmed it. With the other reviewers now at 30, 12 is below the weakest observed code-review ceiling and relies on "prose uses fewer turns" holding in every future scenario. Prose review can plausibly span multi-chapter documents with Grep-heavy style passes; absent session evidence either way, parity with the raised reviewer floor is preferable to a cap that could silently truncate a future complex prose pass. 20 establishes parity with the floor of the raised caps.
  - `metis` (20) and `briefing-analyst` (20) left unchanged — no truncation observed in v1.2.0 session data. Will be revisited if future sessions produce evidence.

### Testing

- `tests/test-uninstall-merge.sh` wired into `.github/workflows/validate.yml` immediately after `test-settings-merge.sh`. The uninstall null-safety suite was added in 1.2.0 (36 assertions covering `clean_settings_python` / `clean_settings_jq` parity and an 8-fixture cross-impl structural diff) but was never added to the CI job — a future regression in `uninstall.sh`'s null-safety logic would have escaped CI until a developer noticed the uninstall crash in production. Closes the 1.2.0 CI gap.

## [1.2.0] - 2026-04-11

### Added

**Prescribed reviewer sequence (Option C dimension gate):**
- Dimension tracker: complex tasks now have a prescribed review sequence where each reviewer covers a distinct dimension (`bug_hunt`, `code_quality`, `stress_test`, `completeness`, `prose`, `traceability`). The stop-hook names the specific next reviewer to run, removing the "which reviewer do I dispatch next" guessing game that pre-fix sessions struggled with.
- `metis` and `briefing-analyst` wired to `record-reviewer.sh` as dimension-tickers (stress_test and traceability respectively). Previously these agents ran without updating any review state.
- `VERDICT:` contract on reviewer agents: each of `quality-reviewer`, `editor-critic`, `excellence-reviewer`, `metis`, `briefing-analyst` now ends with a `VERDICT: CLEAN|SHIP|FINDINGS|BLOCK (N)` line. The stop-guard reads this verdict to determine whether dimensions were ticked cleanly; `VERDICT: FINDINGS (0)` is treated as CLEAN. Legacy phrase-based regex preserved as fallback.
- Doc-vs-code edit routing: `mark-edit.sh` classifies each edit via `is_doc_path` (extensions `.md`/`.mdx`/`.txt`/`.rst`/`.adoc`, well-known basenames, `docs/` path component) and maintains separate `last_code_edit_ts` / `last_doc_edit_ts` clocks. `stop-guard.sh` routes doc-only edits to `editor-critic` instead of `quality-reviewer`, and skips the verification gate for doc-only sessions. Legacy `last_edit_ts` is still written on every edit for backward compatibility.
- `with_state_lock`: portable mkdir-primitive mutex with BSD/GNU `stat` compatibility and 5-second stale-lock recovery. Wraps `tick_dimension` to prevent lost-update races when multiple reviewer SubagentStop hooks fire concurrently.
- `OMC_DIMENSION_GATE_FILE_COUNT` (default 3) and `OMC_TRACEABILITY_FILE_COUNT` (default 6) thresholds, independent of `OMC_EXCELLENCE_FILE_COUNT`. Configurable via env var, `oh-my-claude.conf`, or defaults. Setting `OMC_DIMENSION_GATE_FILE_COUNT` to a high value disables the dimension gate entirely.
- Resumed-session grace: sessions resumed from pre-dimension-gate state get one free stop before the dimension gate enforces the prescribed sequence, preventing mid-task resumes from being force-marched through the full review chain.
- Concise repeat-block messages: block 1 of the stop-guard preserves the verbose "FIRST self-assess" prompt (demonstrably valuable on first pass); blocks 2–3 switch to a `Still missing: X. Next: Y.` form that names only what's un-ticked and the single next action, reducing the summary-inflation pressure observed in pre-fix long sessions.

### Changed

- `record-reviewer.sh` now accepts a reviewer-type argument (`standard|excellence|prose|stress_test|traceability`) to determine which dimensions to tick. Default `standard` preserves the pre-fix behavior for existing wired matchers (quality-reviewer, superpowers/feature-dev code-reviewer, excellence-reviewer). The `editor-critic` matcher was updated to pass `prose`.
- `stop-guard.sh` adds a new Check 4 (Dimension gate) between the existing review/verify gate (Check 3) and the excellence gate (renumbered Check 5). Dimension gate has its own `dimension_guard_blocks` counter (cap 3) that exhausts to `guard_exhausted_detail=dimensions_missing=...` and falls through to the excellence gate rather than bypassing all remaining checks.
- `missing_verify` in stop-guard now keys off `last_code_edit_ts` (not `last_edit_ts`) so doc-only edits after a successful code verification do not re-trigger `npm test`.

### Fixed

- **Review loop pathology on complex tasks.** Pre-fix sessions could get stuck in long review loops because `metis` and `briefing-analyst` were not wired into the stop-guard, the block cap reset on every wired review, and doc edits re-triggered the code-review gate. The dimension gate replaces the guesswork with a prescribed sequence that preserves every catch.
- `get_required_dimensions` legacy fallback (for resumed sessions from pre-dimension-gate state) now classifies each path in `edited_files.log` via `is_doc_path` rather than counting blindly. A resumed doc-only session previously would have routed through the code dimension set.
- **Multi-hook matcher collision in settings merger** (metis finding #1, deeply). A base entry with multiple hooks and a patch entry with one hook that shared a script basename with the base would signature-differ under the old tuple-based scheme and both survive the merge — causing the shared script to fire twice per `SubagentStop` event. **Upgrade note:** if you see `record-reviewer.sh` firing twice per editor-critic or quality-reviewer stop (observable as duplicate dimension ticks in `~/.claude/quality-pack/state/*/session_state.json`), re-running `bash install.sh` heals existing duplicate entries automatically via the `normalize_base_entries` pre-pass. The merger now uses:
  1. A `normalize_base_entries` pre-pass that (a) deduplicates hooks within each entry by script basename (later-wins) and (b) collapses multiple same-matcher entries whose basename sets overlap into a single canonical entry. This closes the migration path where an older buggy installer left two `editor-critic` entries in base settings — without pre-normalization, a three-phase merge's Phase 1 would match only the first entry and leave the second's stale `record-reviewer.sh` still firing.
  2. A three-phase merge over the normalized base: exact `(matcher, basename-set)` match replaces in place; same-matcher-plus-overlapping-basenames triggers hook-level merge (patch hooks replace base hooks sharing a basename, new basenames append); disjoint entries append as before. Disjoint same-matcher entries with different scripts are left separate to preserve intentional user customization.
  3. Null-safe Python accessors via `.get() or default` for `hooks`, `<event>`, `matcher`, and `command` so an explicit `null` in any of those positions doesn't crash Python (matches jq's `// default` coalesce).
  4. jq `sets_equal` switched from `sort` to `unique` so duplicate-basename base entries compare set-semantically under both impls.
  5. Malformed-hook filtering via `isinstance(h, dict)` / `select(type == "object")` so a `null` entry inside a hook entry's `hooks` array doesn't crash Python and both impls produce identical output.
  6. jq `script_basename` whitespace pattern widened from `[ \t]+` to `[ \t\r\n\f\v]+` so pathological commands containing embedded newlines basename-extract identically to Python's default-whitespace `.split()`. Prior narrow pattern produced a latent divergence where a command like `record-reviewer.sh\njunk` would group-key as `record-reviewer.sh` in Python but `record-reviewer.sh\njunk` in jq, causing different merge outcomes.
  Fixes both `merge_settings_python` and `merge_settings_jq` with strict cross-impl parity, verified by a structural diff (`jq -S . py | diff jq`) across 14 fixtures including three-base-entry migration and embedded-newline commands.
- **`quality-reviewer` truncation on complex reviews.** Review sessions were hitting the agent's `maxTurns: 12` cap mid-investigation (observed as "Done (~19 tool uses · ~50s)" on cross-file reviews). The 12-turn cap was introduced in 1.1.0 "to limit context bloat", but reviewer output flows back through `reflect-after-agent.sh` which already hard-truncates the injection at 1000 chars via `truncate_chars 1000` — internal tool-use budget has no effect on parent-session context bloat. Raised `quality-reviewer` `maxTurns` from 12 to 20, matching `metis: 20` (similar investigative profile). `editor-critic` left at 12 because prose reviews use fewer tool calls and no truncation was observed there.
- **Top-level key null-coalesce parity in settings merger.** Python `setdefault("outputStyle", ...)` and `setdefault("effortLevel", ...)` only guard against missing keys and leave a present-but-null value unchanged, diverging from jq's `// default` behavior which coalesces null to the patch default. A user with `{"outputStyle": null}` in `settings.json` would get different settings depending on whether `python3` was available. Fixed by switching both keys to an explicit `if settings.get(key) is None` guard, matching jq's coalesce semantics. Found by excellence-reviewer post the initial merger commit.
- **`uninstall.sh clean_settings_python` null-crash parity.** The uninstaller had a symmetric null-safety bug class to the one closed in install.sh: `settings["hooks"] == None` crashed on `.keys()`, `hook["command"] == None` crashed on `pat in None` (TypeError), and null entries/hooks inside a valid event crashed list iteration. `clean_settings_jq` also silently dropped events whose filtered valid-entries list was empty due to a missing non-object passthrough. Both impls are now null-safe via the same `isinstance(h, dict)` / `select(type == "object")` patterns used in `install.sh`, and null entries/hooks are preserved in both paths rather than diverging on filter behavior. New `tests/test-uninstall-merge.sh` covers the fix with 36 assertions including an 8-fixture cross-impl structural diff.
- **`statusline.py` hangs on slow git subprocess calls.** The statusline widget would freeze indefinitely when `git` subprocess calls blocked (e.g., a stale lock file held by a stalled process in the parent repo), locking up the Claude Code UI around it. `run_git()` now wraps `subprocess.run` with `timeout=2` and catches `TimeoutExpired`, falling back to a neutral empty-stdout `CompletedProcess(returncode=1)` so downstream consumers see a normal failed-git result instead of hanging. New regression coverage in `test_statusline.py`.

### Testing

- `test-common-utilities.sh` (now 158 tests): added coverage for `is_doc_path` (extensions, basenames, path components, negatives), `reviewer_for_dimension` mapping, `tick_dimension` / `is_dimension_valid` (including same-second and post-edit invalidation), `missing_dimensions`, `get_required_dimensions` (counters + legacy fallback with log classification), `with_state_lock` (acquire/release, exit propagation, stale recovery).
- `test-e2e-hook-sequence.sh` (now 116 tests): added coverage for VERDICT parsing (CLEAN / FINDINGS / FINDINGS(0) / last-match-wins / legacy fallback), doc-vs-code routing (separate clocks, doc-only skip verify, code edit after review, doc edit routes to editor-critic), dimension tracker (full Sugar-Tracker-style flow, doc-edit mixed scenario, 6+ file traceability, below-threshold bypass, post-tick code invalidation, doc-edit partial invalidation, exhaustion), concise repeat messages, resumed-session grace.
- `test-settings-merge.sh` (now 153 tests): updated SubagentStop count from 8 to 10; added name assertions for `metis`, `briefing-analyst`, and `editor-critic` matcher commands. Added four new scenario blocks:
  - **Test 9** (18 assertions) — multi-hook matcher collision: base with two hooks vs patch with one hook sharing a basename must consolidate into a single entry with the user's non-overlapping hook preserved, the patch hook replacing the overlapping basename, and idempotent re-merges.
  - **Test 10** (16 assertions, +6 idempotency) — multi-base-entry migration gap: base with two pre-existing same-matcher entries (the migration state from an older buggy installer) must consolidate into one entry with the shared script appearing exactly once. Direct regression test for the metis finding that the shallow Test 9 fix didn't close, plus explicit re-merge idempotency coverage of the normalize_base_entries pre-pass.
  - **Test 11** (10 assertions) — null-safety parity: explicit `null` at `hooks`, `<event>`, `matcher`, and `command` positions must not crash either merger and must produce identical output.
  - **Test 12** (6 assertions) — malformed-hook filtering: a `null` element inside a hook entry's `hooks` array or an event's entries array must not crash either merger. Both impls now filter non-object hooks via `isinstance(h, dict)` / `select(type == "object")`.
  - **Cross-impl structural diff** (15 fixtures) — previously only hook counts were compared cross-impl, which could miss a divergence like "py: 1 hook, jq: 2 hooks" at the same count. Now runs 15 non-trivial fixtures through both impls and asserts byte-for-byte equality of `jq -S . py` vs `jq -S . jq`, including three-same-matcher-entry migration, embedded-newline command, disjoint same-matcher (Test 8 preservation under normalize_base_entries), and null-top-level-keys fixtures.
- **New `test-uninstall-merge.sh` suite** (36 assertions) covering the uninstall null-safety fix: valid fresh-install cleanup, user customization preservation, mixed OMC+user entry preservation, six null-safety scenarios (hooks/event/entry/hook/command/matcher at null positions), and an 8-fixture cross-impl structural diff. Mirrors the test-settings-merge.sh structure for consistency.
- Zero regressions across all 9 test suites (703 tests total, all passing).

## [1.1.0] - 2026-04-09

### Added

**Installer & configuration:**
- `--model-tier` flag with quality/balanced/economy presets for controlling subagent model usage.
- `--no-ios` flag to skip iOS specialist agents (~1200 tokens saved per session).
- `--uninstall` flag on `install.sh` (delegates to `uninstall.sh`).
- `jq` dependency check at install time with actionable error message.
- `switch-tier.sh` convenience script for post-install model tier switching from anywhere.
- Repo path persistence in `oh-my-claude.conf` for automatic update detection.
- AI-assisted install/update prompts in README.
- README: version badge linking to changelog.
- Version infrastructure: `VERSION` file as canonical source of truth.
- Installer now displays version in completion summary and writes `installed_version` to `oh-my-claude.conf`.

**Statusline:**
- Version display in line one.
- Token usage tracking (input/output counts, e.g. `245.3k↑ 18.8k↓`).
- Rate limit usage indicator (`RL:%`) with color-coded thresholds.
- Cost qualifier (`*`) when ULW active to signal subagent costs are excluded.
- Prompt cache hit ratio (`C:%`) from cache-eligible token breakdown.
- API latency indicator (`API:%`) showing API wait time as percentage of wall clock.
- `[ULW:domain]` indicator in magenta when ultrawork mode is active.

**Quality gates & workflow:**
- `excellence-reviewer` agent for fresh-eyes holistic evaluation on complex tasks.
- Verify-outcome gate: blocks stop when tests ran but failed.
- Review-remediation gate: blocks stop when review findings are unaddressed.
- Excellence gate: blocks stop in sessions with 3+ edited files when no excellence review recorded.
- Guard-exhaustion warning on penultimate block (visible to both model and user).
- Pre-review self-assessment: must enumerate request components before invoking reviewer.
- Planner implied-scope section for what a veteran would also deliver.
- Completeness and excellence evaluation added to quality reviewer output.
- Summary restatement cues when stop-guard blocks (prevents lost summaries after continuation).
- Plan persistence via `SubagentStop` hook (`record-plan.sh`).
- Stop-guard messages prefixed with `[GateName · N/M]` block counters.

**Skills & observability:**
- `/ulw-status` skill for inspecting session state and hook decisions.
- `/skills` command lists all available skills with decision guide.
- `/ulw-off` skill to deactivate ultrawork mode mid-session.
- Optional hook debug log via `hook_debug=true` in config or `HOOK_DEBUG=1` env var.
- Bare-imperative intent detection: prompts starting with action verbs now classify as execution.
- Terse continuation detection: `next`, `go on`, `proceed`, `finish the rest` classify correctly.
- Session state TTL sweep: auto-cleans state dirs older than 7 days.
- Configurable thresholds: `stall_threshold`, `excellence_file_count`, `state_ttl_days` via `oh-my-claude.conf`.
- Custom test patterns via `custom_verify_patterns` in `oh-my-claude.conf`.

**Testing:**
- End-to-end integration tests (`test-e2e-hook-sequence.sh`, 38 assertions).
- Quality gates tests (`test-quality-gates.sh`, 43 assertions).
- Settings merge tests (`test-settings-merge.sh`, 62 assertions).
- Common utilities tests (`test-common-utilities.sh`, 83 assertions).
- Statusline widget tests (`test_statusline.py`, 52 assertions).
- Session resume tests (`test-session-resume.sh`, 34 assertions).
- Intent classification test harness (60 cases).
- Stall detection tests (10 cases).
- Configurable threshold tests (18 cases).
- CI now runs all test suites (previously only lint/syntax).
- `verify.sh`: `record-plan.sh`, `ulw-deactivate.sh`, and `record-reviewer.sh` hook validation.

### Changed

- **Stall detection** now tracks unique file paths in a sliding window with tiered responses (8+ unique = silent reset, 4-7 = lighter nudge, <4 = strong warning).
- **Intent classification** converted from 6 grep spawns to bash regex for faster prompt routing.
- **Domain classification** enhanced with bigram matching and negative keywords (e.g., "write tests" → coding, "draft email" → writing).
- **Reviewer agents** produce structured, front-loaded output (executive summary + top-8 findings, 800-word cap) to survive context compression.
- **Reviewer `maxTurns`** reduced from 20 to 12 to limit context bloat.
- **Review injection** widened: `reflect-after-agent` 400→1000 chars, `prompt-intent-router` 220→400 chars.
- **Stop-guard blocks** raised from 2 to 3 before exhaustion.
- **Implementation agents** (9 total) now default to Sonnet model instead of inheriting Opus.
- **Bundle directory** renamed from `bundle/.claude` to `bundle/dot-claude` to avoid permission prompts during development.
- **Compaction snapshot** capped at 2000 characters.
- **Thinking directive** deduplicated (was 3-5x copies per context window).
- **Test coverage** for new features and bug fixes is now a completeness criterion in core rules.
- `switch-tier.sh` performs in-place agent model updates instead of full reinstall.
- Additional review-capable agents registered in PostToolUse hooks (`excellence-reviewer`, third-party code reviewers).

### Fixed

- `BASH_REMATCH` index bug in continuation directive extraction (silently discarded directives like "carry on, but skip tests").
- Sticky ULW gate: post-compaction continuation prompts lost specialist routing when `workflow_mode` was already "ultrawork".
- Bash verification recording gap: `bash`, `shellcheck`, `bash -n` commands weren't tracked as verifications.
- Empty model tier display when only `repo_path` was in config.
- `switch-tier.sh` missing from uninstall cleanup (orphaned on uninstall).
- Missing executable bit on `switch-tier.sh`.
- `get_conf()` truncated values containing `=` characters (wrong `cut` field range).
- Race condition where excellence reviews overwrote `review_had_findings` from standard review.
- Architecture.md drift: stale values for common.sh line count, stop-guard cap, missing state keys.
- AGENTS.md architecture diagram and test section updated to list all 8 test files (was 4).
- README coding chain now uses actual agent filenames for consistency.
- CI shellcheck failures resolved (`.shellcheckrc` added, unused variables removed).

### Removed

- `sisyphus` and `ultrawork` skill aliases (replaced by `autowork` + `ulw`).
- Stale completed plan file (`docs/plans/2026-04-07-ulw-improvements.md`).
- Unused `read_hook_json()` function from `common.sh`.
- Dead code: unused variables `previous_workflow_mode`, `previous_task_intent` from prompt-intent-router.

## [1.0.0] - 2026-04-06

Initial public release.

### Added

- Cognitive quality harness with hard stop gates to enforce thinking before acting.
- Intent classification state machine covering 5 intents and 6 domains.
- Git tag `v1.0.0` on initial release commit.
- Multi-domain routing for coding, writing, research, operations, and mixed workloads.
- 23 specialist agents with permission boundaries enforced via disallowedTools.
- Session continuity across compaction via pre-compact snapshots and post-compact handoff.
- Merge-safe installer with automatic backup of existing configuration.
- OpenCode Compact output style for concise, structured responses.
- Custom statusline with context usage tracking.
