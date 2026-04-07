# oh-my-claude

Cognitive quality harness for Claude Code -- bash hooks, specialist agents, and skills that enforce thinking, testing, and review. Pure bash, zero npm dependencies. Installs as a merge-safe overlay into `~/.claude/`.

## Key Directories

- `bundle/dot-claude/agents/` -- 22 specialist agent definitions with permission boundaries
- `bundle/dot-claude/quality-pack/scripts/` -- lifecycle hook scripts (prompt routing, compaction, session management)
- `bundle/dot-claude/skills/` -- skill definitions and autowork hook scripts
- `bundle/dot-claude/skills/autowork/scripts/common.sh` -- shared utility library (state, JSON, classification)
- `config/settings.patch.json` -- settings merged into user config on install

## Testing

```bash
bash -n bundle/dot-claude/**/*.sh
shellcheck bundle/dot-claude/**/*.sh
bash verify.sh
```

## Rules

- Never hardcode user paths. Use `$HOME` or relative paths.
- All bash scripts must use `set -euo pipefail`.
- Hook scripts must source `common.sh` and exit 0 on missing `SESSION_ID`.
- State is JSON in `session_state.json`, accessed via `read_state` / `write_state`.
