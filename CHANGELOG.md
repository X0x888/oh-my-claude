# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- **Serendipity Rule in `core.md`** — new bullet in the gold-plating section tells Claude to fix verified adjacent defects discovered mid-task when they live on the same code path and the fix is bounded (no separate investigation or new test scaffolding); otherwise the defect goes to a `project_*.md` memory **and** is named in the session summary as a deferred risk, so verified known defects are not buried in memory-only bookkeeping. The existing "no future-session handoffs" rule now cross-references it. Originating case: an iOS session deferred a verified cursor-jitter guard in the same post-frame window as a just-fixed text-loss bug — prior rules only addressed *additions* (gold-plating), not adjacent-defect triage.
- **Reviewer coverage of the Serendipity Rule** — `quality-reviewer.md` gains priority #9 and `excellence-reviewer.md` gains axis #5. Both flag should-have-fixed deferrals that meet the full three-condition test from `core.md` (verified + same code path + bounded fix with no separate investigation or new test scaffolding), and both flag verified-but-deferred defects that were dropped into a memory without being surfaced in the session summary. Unverified/theoretical/cross-module deferrals remain correctly deferred.

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
