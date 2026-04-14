# oh-my-claude

Cognitive quality harness for Claude Code -- bash hooks, specialist agents, and skills that enforce thinking, testing, and review. Pure bash, zero npm dependencies. Installs as a merge-safe overlay into `~/.claude/`.

## Key Directories

- `bundle/dot-claude/agents/` -- 30 specialist agent definitions with permission boundaries
- `bundle/dot-claude/quality-pack/scripts/` -- 5 lifecycle hook scripts (prompt routing, compaction, session management)
- `bundle/dot-claude/skills/` -- 17 skill definitions, each in `<name>/SKILL.md`
- `bundle/dot-claude/skills/autowork/scripts/` -- 12 autowork hook scripts including `common.sh` (shared utility library)
- `bundle/dot-claude/output-styles/` -- output format templates
- `config/settings.patch.json` -- settings merged into user config on install
- `tests/` -- 9 test scripts (e2e hook sequence, intent classification, quality gates, stall detection, settings merge, uninstall merge, common utilities, session resume, statusline)
- `docs/` -- architecture, customization, FAQ, and prompt reference docs

## Key Files

- `VERSION` -- canonical version source of truth (single line, e.g. `1.0.0`)
- `install.sh` -- merge-safe installer (supports `--bypass-permissions`, `--no-ios`, `--model-tier`)
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
python3 -m unittest tests.test_statusline -v
```

## Rules

- Never hardcode user paths. Use `$HOME` or relative paths.
- All bash scripts must use `set -euo pipefail`.
- Hook scripts must source `common.sh` and exit 0 on missing `SESSION_ID`.
- State is JSON in `session_state.json`, accessed via `read_state` / `write_state`.
- Multi-step state updates that are subject to concurrent SubagentStop hooks (e.g. dimension ticks) must go through `with_state_lock` to prevent lost updates. Use `with_state_lock_batch` for multi-key atomic writes.
- Cross-session data (agent metrics, defect patterns) lives in `~/.claude/quality-pack/` as JSON files with their own lock mechanisms. Never store cross-session data inside session directories.
- Guard exhaustion mode (`guard_exhaustion_mode` in `oh-my-claude.conf`) controls behavior when quality gates are exhausted: `scorecard` (default, legacy name: `warn`) emits a scorecard then releases, `block` (legacy: `strict`) keeps blocking, `silent` (legacy: `release`) silently releases. Both old and new names are accepted.
- Gate level (`gate_level` in `oh-my-claude.conf`) controls enforcement depth: `full` (default) enables all gates including review coverage and excellence, `standard` enables quality + excellence gates, `basic` enables only the quality gate.
- Verification confidence threshold (`verify_confidence_threshold` in `oh-my-claude.conf`, default 30) sets the minimum confidence score (0-100) for verification to satisfy the quality gate. Low-confidence verifications (e.g., `bash -n` syntax check) are treated as insufficient.
- Per-project configuration: `load_conf()` reads `$HOME/.claude/oh-my-claude.conf` (user-level), then walks up from `$PWD` looking for `.claude/oh-my-claude.conf` (project-level overrides). Env vars always take precedence over both.
- Prefer readable code over micro-optimizations. When quality and speed conflict, choose quality.
- Do not break existing install paths, config merges, or hook interfaces for performance gains.
- When adding, removing, or renaming agents, skills, scripts, or directories, update README.md, CLAUDE.md, AGENTS.md, and CONTRIBUTING.md to reflect the change. Stale docs are worse than no docs.
- When bumping the version, follow the full release checklist (replace `X.Y.Z` with the actual version in all commands):
  1. Update `VERSION` with the new version number.
  2. Update the README.md version badge to match.
  3. Add a CHANGELOG.md entry under `## [X.Y.Z] - YYYY-MM-DD`.
  4. Commit with a descriptive message summarizing the release.
  5. Tag the release commit: `git tag vX.Y.Z`.
  6. Push commits and tags: `git push && git push --tags`.
  7. Create a GitHub release: `VER=$(cat VERSION) && awk "/^## \\[$VER\\]/{found=1;next} /^## \\[/{if(found)exit} found" CHANGELOG.md | gh release create "v$VER" --title "v$VER" --notes-file -`. If `gh` is unavailable, create the release manually via GitHub's web UI.
  8. Never skip tagging — a version bump without a tag breaks the release history.
- When adding a new reviewer-style agent:
  1. Wire it in `config/settings.patch.json` under `SubagentStop` with a reviewer-type argument (`standard|excellence|prose|stress_test|traceability|design_quality`).
  2. Add the `VERDICT:` contract line to its output format section in `bundle/dot-claude/agents/<name>.md`.
  3. Update the dimension mapping table in `AGENTS.md`.
  4. Add a matcher-name assertion in `tests/test-settings-merge.sh`.
  5. Add a simulator function and at least one sequence test in `tests/test-e2e-hook-sequence.sh`.
  6. Update the `SubagentStop` count assertions in `tests/test-settings-merge.sh`.
