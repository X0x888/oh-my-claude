# AGENTS.md

Instructions for AI agents working on the oh-my-claude repository.

## Project Context

oh-my-claude is a cognitive quality harness for Claude Code. It provides bash hooks, skills, and specialist agents that enforce thinking, testing, and review during AI-assisted development. The system is pure bash with zero npm dependencies.

## Architecture

```
bundle/.claude/
  agents/                   # 22 specialist agent definitions (.md)
  output-styles/            # Output format templates
  quality-pack/
    memory/                 # Core, skills, and compact memory files
    scripts/                # Hook scripts (prompt routing, compaction, session lifecycle)
  skills/                   # Skill definitions, each in <name>/SKILL.md
    autowork/scripts/       # Shared hook scripts and utilities
      common.sh             # Shared functions (state, JSON, classification)
  statusline.py             # Custom statusline with context tracking
  CLAUDE.md                 # Installed user-facing CLAUDE.md

config/
  settings.patch.json       # Settings merged into user's settings.json
```

### Key Components

- **Hook scripts** (`quality-pack/scripts/`, `autowork/scripts/`): Bash scripts triggered by Claude Code lifecycle events (prompt entry, compaction, session start). They route intents, manage state, and enforce quality gates.
- **common.sh** (`autowork/scripts/common.sh`): Shared utility library. Provides JSON state management (`read_state`, `write_state`, `write_state_batch`), session directory helpers, intent classification (`classify_task_intent`), and domain routing.
- **Agent definitions** (`agents/*.md`): Markdown files defining specialist agents with role descriptions, capabilities, and `disallowedTools` for permission boundaries.
- **Skills** (`skills/<name>/SKILL.md`): Self-contained skill definitions invoked by slash commands or automatic routing.
- **Settings patch** (`config/settings.patch.json`): JSON configuration merged into the user's Claude Code settings during installation.

### State Management

Session state is stored as JSON in `$HOME/.claude/quality-pack/state/<session_id>/session_state.json`. All state reads and writes go through `read_state` and `write_state` / `write_state_batch` in `common.sh`.

## Conventions

### Bash Scripts

- All scripts begin with `set -euo pipefail`.
- Hook scripts source `common.sh` for shared utilities.
- Hook scripts must exit 0 when `SESSION_ID` is missing or empty. This is a safety guard for cases where the hook is invoked outside a valid session.
- Never hardcode user paths. Use `$HOME` or relative paths.

### State

- All state is JSON, stored in `session_state.json` per session.
- Use `write_state_batch` for atomic multi-key updates.
- Use `read_state` for reads; it returns empty string for missing keys.

### Agents

- Each agent is a single `.md` file in `bundle/.claude/agents/`.
- Agents use `disallowedTools` to enforce permission boundaries (e.g., a reviewer agent cannot edit files).
- Agent names should be descriptive and hyphen-separated.

## Testing

Run these before submitting changes:

```bash
# Syntax validation
bash -n bundle/.claude/**/*.sh

# Linting
shellcheck bundle/.claude/**/*.sh

# Integration verification
bash verify.sh
```

## Protected Design Decisions

Do not change these without discussion in a GitHub issue:

1. **Intent classification order in `classify_task_intent()`**: Imperative intents are matched before advisory intents. This ensures explicit action requests are never misclassified as advice-seeking.

2. **Stop guard block limits**: Hard-capped at 2 per session. This prevents runaway execution while still allowing one retry after a warning.

3. **Agent permission boundaries via `disallowedTools`**: Each agent's `.md` file specifies which tools it cannot use. This is the primary security boundary -- do not weaken an agent's restrictions without a clear justification.

4. **40% threshold for mixed domain classification**: When no single domain exceeds 40% of signal weight, the task is classified as "mixed" and routed to a generalist agent. Changing this threshold affects routing accuracy across all intents.

## Adding New Components

### Adding an Agent

1. Create `bundle/.claude/agents/<agent-name>.md`.
2. Define the agent's role, capabilities, and constraints.
3. Specify `disallowedTools` to enforce permission boundaries appropriate to the role.
4. If the agent handles a specific domain, ensure `classify_task_domain()` in `common.sh` can route to it.

### Adding a Skill

1. Create `bundle/.claude/skills/<skill-name>/SKILL.md`.
2. Define trigger conditions, instructions, and any required scripts.
3. If the skill needs hook scripts, place them in `bundle/.claude/skills/<skill-name>/scripts/`.

### Adding a Hook Script

1. Place the script in the appropriate directory:
   - Lifecycle hooks: `bundle/.claude/quality-pack/scripts/`
   - Autowork hooks: `bundle/.claude/skills/autowork/scripts/`
2. Begin with `set -euo pipefail`.
3. Source `common.sh`: `. "${HOME}/.claude/skills/autowork/scripts/common.sh"`
4. Exit 0 on missing `SESSION_ID`.
5. Register the hook in `config/settings.patch.json` under the appropriate event.
