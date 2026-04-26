# oh-my-claude

Cognitive quality harness for Claude Code -- bash hooks, specialist agents, and skills that enforce thinking, testing, and review. Pure bash, zero npm dependencies. Installs as a merge-safe overlay into `~/.claude/`.

## Key Directories

- `bundle/dot-claude/agents/` -- 31 specialist agent definitions with permission boundaries
- `bundle/dot-claude/quality-pack/scripts/` -- 5 lifecycle hook scripts (prompt routing, compaction, session management)
- `bundle/dot-claude/skills/` -- 19 skill definitions, each in `<name>/SKILL.md`
- `bundle/dot-claude/skills/autowork/scripts/` -- 20 autowork hook scripts including `common.sh` (shared utility library), `record-finding-list.sh` (council Phase 8 master finding list), `record-serendipity.sh` (Serendipity Rule analytics), `record-archetype.sh` (cross-session archetype memory), `find-design-contract.sh` (resolves the active session's inline-emitted Design Contract for design-reviewer / visual-craft-lens), and `mark-deferred.sh` (backs the `/mark-deferred` skill — bulk-defers pending discovered_scope rows with a one-line reason); state I/O extracted to `lib/state-io.sh`, the prompt classifier extracted to `lib/classifier.sh`, and the verification subsystem extracted to `lib/verification.sh`, all sourced by `common.sh`
- `bundle/dot-claude/output-styles/` -- output format templates
- `config/settings.patch.json` -- settings merged into user config on install
- `tests/` -- 31 bash + 1 python test scripts (e2e hook sequence, intent classification, quality gates, stall detection, settings merge, uninstall merge, common utilities, session resume, concurrency, cross-session-lock, install artifacts, post-merge hook, repro redaction, discovered-scope, finding-list, mark-deferred, state-io, classifier-replay, serendipity-log, cross-session-rotation, classifier, show-report, install-remote, phase8-integration, verification-lib, agent-verdict-contract, gate-events, discover-session, design-contract, inline-design-contract, archetype-memory, plus python `test_statusline.py`)
- `tools/` -- Developer-only tools (`replay-classifier-telemetry.sh` and `classifier-fixtures/regression.jsonl`); not installed into `~/.claude/`
- `docs/` -- architecture, customization, FAQ, and prompt reference docs

## Key Files

- `VERSION` -- canonical version source of truth (single line, e.g. `1.0.0`)
- `install.sh` -- merge-safe installer (supports `--bypass-permissions`, `--no-ios`, `--model-tier`)
- `install-remote.sh` -- curl-pipe-bash bootstrapper that clones to `~/.local/share/oh-my-claude` then runs `install.sh`
- `uninstall.sh` -- clean removal of installed harness
- `verify.sh` -- post-install integrity checker (paths, JSON, hooks, syntax)
- `bundle/dot-claude/switch-tier.sh` -- convenience script to switch model tier post-install
- `bundle/dot-claude/statusline.py` -- custom Claude Code statusline widget

## Testing

```bash
# Syntax + lint
bash -n bundle/dot-claude/**/*.sh
shellcheck bundle/dot-claude/**/*.sh

# Installation verification
bash verify.sh

# Unit / integration tests
bash tests/test-intent-classification.sh
bash tests/test-quality-gates.sh
bash tests/test-stall-detection.sh
bash tests/test-e2e-hook-sequence.sh
bash tests/test-settings-merge.sh
bash tests/test-uninstall-merge.sh
bash tests/test-common-utilities.sh
bash tests/test-session-resume.sh
bash tests/test-concurrency.sh
bash tests/test-install-artifacts.sh
bash tests/test-post-merge-hook.sh
bash tests/test-repro-redaction.sh
bash tests/test-discovered-scope.sh
bash tests/test-finding-list.sh
bash tests/test-state-io.sh
bash tests/test-classifier-replay.sh
bash tests/test-serendipity-log.sh
bash tests/test-cross-session-rotation.sh
bash tests/test-classifier.sh
bash tests/test-show-report.sh
bash tests/test-install-remote.sh
bash tests/test-phase8-integration.sh
bash tests/test-verification-lib.sh
bash tests/test-agent-verdict-contract.sh
bash tests/test-gate-events.sh
bash tests/test-discover-session.sh
bash tests/test-design-contract.sh
bash tests/test-inline-design-contract.sh
bash tests/test-archetype-memory.sh
bash tests/test-cross-session-lock.sh
bash tests/test-mark-deferred.sh
python3 -m unittest tests.test_statusline -v
```

## Rules

- Never hardcode user paths. Use `$HOME` or relative paths.
- All bash scripts must use `set -euo pipefail`.
- Hook scripts must source `common.sh` and exit 0 on missing `SESSION_ID`.
- State is JSON in `session_state.json`, accessed via `read_state` / `write_state`.
- Multi-step state updates that are subject to concurrent SubagentStop hooks (e.g. dimension ticks) must go through `with_state_lock` to prevent lost updates. Use `with_state_lock_batch` for multi-key atomic writes.
- Cross-session data (agent metrics, defect patterns) lives in `~/.claude/quality-pack/` as JSON files with their own lock mechanisms. Never store cross-session data inside session directories.
- Cross-session project identity uses `_omc_project_key` (git-remote-first, cwd-hash fallback) — survives worktrees and clones at different paths. Use `_omc_project_id` (cwd-only) only when the cwd-divergence is the actual signal you want (e.g., per-directory gate-skip counts). For "is this the same upstream project?" semantics — archetype memory, etc. — prefer `_omc_project_key`.
- Inline design contracts emitted by `frontend-developer` / `ios-ui-developer` are captured at SubagentStop into `<session>/design_contract.md` (markdown, not JSON). The `design-reviewer` and `visual-craft-lens` agents resolve this prior via `find-design-contract.sh` when no project-root `DESIGN.md` exists.
- Guard exhaustion mode (`guard_exhaustion_mode` in `oh-my-claude.conf`) controls behavior when quality gates are exhausted: `scorecard` (default, legacy name: `warn`) emits a scorecard then releases, `block` (legacy: `strict`) keeps blocking, `silent` (legacy: `release`) silently releases. Both old and new names are accepted.
- Gate level (`gate_level` in `oh-my-claude.conf`) controls enforcement depth: `full` (default) enables all gates including review coverage and excellence, `standard` enables quality + excellence gates, `basic` enables only the quality gate.
- Verification confidence threshold (`verify_confidence_threshold` in `oh-my-claude.conf`, default 40) sets the minimum confidence score (0-100) for verification to satisfy the quality gate. Lint-only checks like `shellcheck` (score 30) and `bash -n` (score 30) are blocked at the default threshold; project test suites (score 70+) and framework runs with output signals (score 50+) pass. MCP verification tools (Playwright, computer-use) have base scores below threshold (15-35); they only pass when output carries assertion signals or when recent edits include UI files (+20 context bonus).
- Discovered-scope tracking (`discovered_scope` in `oh-my-claude.conf`, default `on`) controls whether findings emitted by advisory specialists (council lenses, `metis`, `briefing-analyst`) are captured to `<session>/discovered_scope.jsonl` and gated by stop-guard before a session is allowed to stop. The gate fires when `pending` rows exist and `task_intent` is `execution`/`continuation` — the model must explicitly ship, defer-with-reason, or call out each finding before stopping. Cap: 2 blocks per session by default; raised to `wave_total + 1` when a council Phase 8 wave plan is active (so the gate stays useful across multiple legitimate wave-by-wave commits). Set to `off` as a kill switch when heuristic extraction is too noisy on a particular project's prose style.
- Council Phase 8 (Execution Plan) bridges council assessment to wave-based implementation when the prompt requests fixes (markers: "implement all", "exhaustive", "fix everything", "make X impeccable", etc.). The model invokes `record-finding-list.sh` to persist the master finding list to `<session>/findings.json`, groups findings into 5–10-finding waves by surface area, and executes each wave fully (`quality-planner` → implementation specialist → `quality-reviewer` on the wave's diff → `excellence-reviewer` for the wave's surface → verification → per-wave commit titled `Wave N/M: <surface> (F-xxx, ...)`) before starting the next wave. Phase 8 is auto-injected by `prompt-intent-router.sh` when `is_council_evaluation_request` matches AND `is_execution_intent_value` is true; it is skipped on advisory-only prompts. Five-priority rule from `/council` governs presentation order (top of report), not execution scope — exhaustive-implementation prompts execute all findings, with the rank determining wave ordering.
- Council deep-default (`council_deep_default` in `oh-my-claude.conf`, default `off`) controls whether auto-triggered council dispatches (broad project-evaluation prompts under `/ulw` that match `is_council_evaluation_request`) inherit `--deep` behavior — i.e., lens dispatches use `model: opus` instead of the default `sonnet`. Set to `on` for quality-first users who want every auto-triggered council to be opus-grade; explicit `/council --deep` invocations always escalate regardless of this flag, and explicit `/council` (no flag) is unaffected. Cost: meaningfully higher per auto-triggered council run. The router also honors an inline `--deep` token in the prompt text (e.g., `/ulw evaluate the project --deep`) — this works independently of the conf flag.
- Per-project configuration: `load_conf()` reads `$HOME/.claude/oh-my-claude.conf` (user-level), then walks up from `$PWD` looking for `.claude/oh-my-claude.conf` (project-level overrides). Env vars always take precedence over both.
- Prefer readable code over micro-optimizations. When quality and speed conflict, choose quality.
- Do not break existing install paths, config merges, or hook interfaces for performance gains.
- When adding, removing, or renaming agents, skills, scripts, or directories, update README.md, CLAUDE.md, AGENTS.md, and CONTRIBUTING.md to reflect the change. Stale docs are worse than no docs.
- When adding or removing a user-invocable skill, update all three skill lists in lockstep: `README.md` (skill table), `bundle/dot-claude/skills/skills/SKILL.md` (user-facing index), and `bundle/dot-claude/quality-pack/memory/skills.md` (in-session memory). Missing entries cause either a discoverability gap (user can't find the skill) or a memory gap (Claude doesn't know to suggest it).
- When adding or removing a skill directory or agent file, update both `verify.sh` (`required_paths`) AND `uninstall.sh` (`SKILL_DIRS` / `AGENT_FILES`) in the same commit. These two lists must stay parallel — otherwise uninstall leaks files or verify silently passes a broken install.
- When bumping the version, follow the full release checklist (replace `X.Y.Z` with the actual version in all commands):
  1. **Pre-flight CHANGELOG audit.** Run `git log --oneline vPREV..HEAD` and confirm every commit has a matching CHANGELOG `[Unreleased]` bullet. Silent drop (a large commit's changes missing from the changelog) is the common failure mode. Also skim `docs/architecture.md` state-key table for new keys introduced in the window.
  2. Update `VERSION` with the new version number.
  3. Update the README.md version badge to match.
  4. Promote the `[Unreleased]` heading in `CHANGELOG.md` to `## [X.Y.Z] - YYYY-MM-DD` (keep `[Unreleased]` above it as an empty placeholder for the next cycle if desired).
  5. Commit with a descriptive message summarizing the release.
  6. Tag the release commit: `git tag vX.Y.Z`.
  7. Push commits and tags: `git push && git push --tags`.
  8. Create a GitHub release: `VER=$(cat VERSION) && awk "/^## \\[$VER\\]/{found=1;next} /^## \\[/{if(found)exit} found" CHANGELOG.md | gh release create "v$VER" --title "v$VER" --notes-file -`. If `gh` is unavailable, create the release manually via GitHub's web UI.
  9. Never skip tagging — a version bump without a tag breaks the release history.
- When adding a new reviewer-style agent:
  1. Wire it in `config/settings.patch.json` under `SubagentStop` with a reviewer-type argument (`standard|excellence|prose|stress_test|traceability|design_quality`).
  2. Add the `VERDICT:` contract line to its output format section in `bundle/dot-claude/agents/<name>.md`.
  3. Update the dimension mapping table in `AGENTS.md`.
  4. Add a matcher-name assertion in `tests/test-settings-merge.sh`.
  5. Add a simulator function and at least one sequence test in `tests/test-e2e-hook-sequence.sh`.
  6. Update the `SubagentStop` count assertions in `tests/test-settings-merge.sh`.
