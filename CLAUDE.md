# oh-my-claude

Cognitive quality harness for Claude Code -- bash hooks, specialist agents, and skills that enforce thinking, testing, and review. Pure bash, zero npm dependencies. Installs as a merge-safe overlay into `~/.claude/`.

## Key Directories

- `bundle/dot-claude/agents/` -- 22 specialist agent definitions with permission boundaries
- `bundle/dot-claude/quality-pack/scripts/` -- 5 lifecycle hook scripts (prompt routing, compaction, session management)
- `bundle/dot-claude/skills/` -- 11 skill definitions, each in `<name>/SKILL.md`
- `bundle/dot-claude/skills/autowork/scripts/` -- 10 autowork hook scripts including `common.sh` (shared utility library)
- `bundle/dot-claude/output-styles/` -- output format templates
- `config/settings.patch.json` -- settings merged into user config on install
- `tests/` -- 4 bash test scripts (e2e hook sequence, intent classification, quality gates, stall detection)
- `docs/` -- architecture, customization, FAQ, and prompt reference docs

## Key Files

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
```

## Rules

- Never hardcode user paths. Use `$HOME` or relative paths.
- All bash scripts must use `set -euo pipefail`.
- Hook scripts must source `common.sh` and exit 0 on missing `SESSION_ID`.
- State is JSON in `session_state.json`, accessed via `read_state` / `write_state`.
- Prefer readable code over micro-optimizations. When quality and speed conflict, choose quality.
- Do not break existing install paths, config merges, or hook interfaces for performance gains.
- When adding, removing, or renaming agents, skills, scripts, or directories, update README.md, CLAUDE.md, AGENTS.md, and CONTRIBUTING.md to reflect the change. Stale docs are worse than no docs.
