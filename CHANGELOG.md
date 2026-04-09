# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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
