# oh-my-claude

Cognitive quality harness for Claude Code -- bash hooks, specialist agents, and skills that enforce thinking, testing, and review. Pure bash, zero npm dependencies. Installs as a merge-safe overlay into `~/.claude/`.

## Key Directories

- `bundle/dot-claude/agents/` -- 29 specialist agent definitions with permission boundaries
- `bundle/dot-claude/quality-pack/scripts/` -- 5 lifecycle hook scripts (prompt routing, compaction, session management)
- `bundle/dot-claude/skills/` -- 14 skill definitions, each in `<name>/SKILL.md`
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
- Multi-step state updates that are subject to concurrent SubagentStop hooks (e.g. dimension ticks) must go through `with_state_lock` to prevent lost updates.
- Prefer readable code over micro-optimizations. When quality and speed conflict, choose quality.
- Do not break existing install paths, config merges, or hook interfaces for performance gains.
- When adding, removing, or renaming agents, skills, scripts, or directories, update README.md, CLAUDE.md, AGENTS.md, and CONTRIBUTING.md to reflect the change. Stale docs are worse than no docs.
- When bumping the version, update `VERSION`, the README badge, and add a CHANGELOG entry. Tag the release commit with `vX.Y.Z`.
- When adding a new reviewer-style agent:
  1. Wire it in `config/settings.patch.json` under `SubagentStop` with a reviewer-type argument (`standard|excellence|prose|stress_test|traceability`).
  2. Add the `VERDICT:` contract line to its output format section in `bundle/dot-claude/agents/<name>.md`.
  3. Update the dimension mapping table in `AGENTS.md`.
  4. Add a matcher-name assertion in `tests/test-settings-merge.sh`.
  5. Add a simulator function and at least one sequence test in `tests/test-e2e-hook-sequence.sh`.
  6. Update the `SubagentStop` count assertions in `tests/test-settings-merge.sh`.
