# Customization

oh-my-claude is designed to be modified. Every component -- agents, quality gates, domain routing, output style, statusline -- is a plain file you can edit directly. This guide covers what's configurable and how to change it without breaking the harness.

---

## Permission Modes

Claude Code prompts for permission before running bash commands, editing files, and similar operations. oh-my-claude supports three approaches:

**Default (prompted)**: Install without flags. Claude Code asks for confirmation on sensitive operations. The harness hooks still fire, but you'll see permission dialogs during normal use.

```bash
bash install.sh
```

**Bypass mode**: Install with `--bypass-permissions`. This skips Claude Code's built-in permission prompts, letting the harness run without interruption. The quality gates (stop guard, review requirement, verification requirement) still apply. Bypass-permissions affects Claude Code's confirmations, not the harness's enforcement.

```bash
bash install.sh --bypass-permissions
```

**Per-session**: You can toggle permissions at any time using Claude Code's built-in `/permissions` command within a session. This does not affect the harness configuration.

---

## Model Tiers

oh-my-claude assigns each specialist agent a model (`opus` or `sonnet`) in its definition file. The default split uses Opus for complex reasoning agents (planning, review, debugging) and Sonnet for faster execution agents (frontend, backend, research).

You can override this split at install time with the `--model-tier` flag:

```bash
bash install.sh --model-tier=quality    # all agents use Opus
bash install.sh --model-tier=balanced   # default split (Opus for planning/review, Sonnet for execution)
bash install.sh --model-tier=economy    # all agents use Sonnet
```

### Switching tiers after installation

A convenience script is installed at `~/.claude/switch-tier.sh` so you can switch tiers from anywhere without navigating to the repository:

```bash
bash ~/.claude/switch-tier.sh quality    # switch to all-Opus
bash ~/.claude/switch-tier.sh economy    # switch to all-Sonnet
bash ~/.claude/switch-tier.sh            # show current tier
```

The script reads the saved repo path from `oh-my-claude.conf` and re-runs the full installer with the new tier. Backups are created as usual.

| Tier | Opus agents | Sonnet agents | Best for |
|---|---|---|---|
| `quality` | All 22 | 0 | Users with high usage limits who prioritize quality over cost |
| `balanced` | 9 (planning, review, debugging, writing, operations) | 13 (execution, research, domain specialists) | Most users (default) |
| `economy` | 0 | All 22 | Users on tighter plans or budget-conscious API usage |

### How it works

The chosen tier is saved to `~/.claude/oh-my-claude.conf`. On subsequent installs, the tier is automatically re-applied unless you pass a different `--model-tier` flag. The flag always takes precedence over the saved value.

For `balanced`, the bundle defaults are used as-is. For `quality` and `economy`, the installer rewrites the `model:` line in each agent's frontmatter after copying the bundle files.

### Per-agent overrides

If you need finer control than the three presets, edit individual agent files after installation:

```bash
# Change a specific agent to use Opus
tmp=$(mktemp) && sed 's/^model: sonnet$/model: opus/' ~/.claude/agents/librarian.md > "$tmp" && mv "$tmp" ~/.claude/agents/librarian.md
```

Per-agent edits are overwritten on the next install. To preserve them, either re-apply manually after each install, or change the agent definition in your local clone of the repository before installing.

### Thinking effort

Agent-level thinking effort (extended thinking budget) is not currently configurable. The `effortLevel` setting in `settings.json` affects only the main thread. This is a Claude Code platform limitation -- when Claude Code adds agent-level thinking control, the tier system can be extended to support it.

---

## Adding Your Own Agents

Agent definitions live in `~/.claude/agents/`. Each agent is a single markdown file with YAML frontmatter.

To add a new agent:

1. Create `~/.claude/agents/<agent-name>.md`.
2. Define the frontmatter:

```yaml
---
name: my-agent
description: When to invoke this agent (shown in agent selection UI).
disallowedTools: Write, Edit, MultiEdit
model: opus
permissionMode: plan
maxTurns: 20
memory: user
---
```

3. Write the agent's system prompt below the frontmatter.

Key settings:

- **`disallowedTools`**: Comma-separated list of tools the agent cannot use. For read-only agents (reviewers, analysts, researchers), set `Write, Edit, MultiEdit` to prevent unsupervised file mutations. The main thread retains exclusive write access.
- **`model`**: Which model the agent uses. Set to `opus` for complex reasoning, `sonnet` for faster/cheaper operations.
- **`maxTurns`**: Maximum number of tool-use turns before the agent must return. Prevents runaway agents.
- **`permissionMode`**: Set to `plan` for read-only agents so they skip permission prompts for non-destructive operations.

---

## Adding Your Own Skills

Skills live in `~/.claude/skills/<skill-name>/SKILL.md`. Each skill is a markdown file with YAML frontmatter that defines when and how it activates.

To add a new skill:

1. Create the directory: `~/.claude/skills/<skill-name>/`
2. Create `SKILL.md` with frontmatter:

```yaml
---
name: my-skill
description: What this skill does (used for matching).
argument-hint: "[task description]"
---
```

3. Write the skill's instructions below the frontmatter.
4. If the skill needs hook scripts, place them in `~/.claude/skills/<skill-name>/scripts/` and register them in `~/.claude/settings.json` under the appropriate hook event.

The skill is invoked with `/my-skill <arguments>`. The `$ARGUMENTS` placeholder in the skill body is replaced with whatever the user passes.

---

## Tuning Quality Gates

The stop guard (`skills/autowork/scripts/stop-guard.sh`) enforces three independent gates. Each has a block limit that caps how many times it can prevent Claude from stopping.

### Adjusting block limits

Edit `stop-guard.sh` and change the comparison values:

- **Advisory inspection gate** (line ~52): `advisory_guard_blocks -lt 1` -- Change `1` to increase or decrease the cap.
- **Session handoff gate** (line ~68): `session_handoff_blocks -lt 2` -- Change `2`.
- **Review/verification gate** (line ~114): `guard_blocks -ge 2` -- Change `2`.

Setting any cap to `0` effectively disables that gate.

### Disabling a specific guard

To disable a guard entirely, add `exit 0` at the beginning of its check block, or remove the corresponding section from the script. For example, to disable the session handoff guard, comment out or remove the `has_unfinished_session_handoff` block (lines ~65-73).

To disable all quality gates, remove the Stop hook entry from `~/.claude/settings.json`:

```json
"Stop": []
```

### Disabling verification for non-code domains

The stop guard already skips the verification check for writing, research, operations, and general domains. It only requires `last_verify_ts` for coding and mixed tasks. To change which domains require verification, edit the `case` statement on lines ~93-102 of `stop-guard.sh`.

---

## Domain Keywords

The domain classifier (`infer_domain()` in `skills/autowork/scripts/common.sh`) scores prompts by counting keyword matches. To improve classification for your workflow, add keywords to the relevant pattern.

Each domain's keywords are defined as a regex pattern passed to `count_keyword_matches`. For example, the coding keywords:

```bash
coding_score=$(count_keyword_matches '\b(bugs?|fix|debug|refactor|implement|...)\b' "${text}")
```

To add a keyword:

1. Open `~/.claude/skills/autowork/scripts/common.sh`.
2. Find the `infer_domain()` function (around line 320).
3. Add your keyword to the appropriate domain's regex pattern, separated by `|`.
4. Keywords are matched case-insensitively. Use `\b` word boundaries to avoid partial matches.

Example -- adding "terraform" and "ansible" to the coding domain:

```bash
coding_score=$(count_keyword_matches '\b(...|terraform|ansible)\b' "${text}")
```

---

## Cognitive Defaults

The file `~/.claude/quality-pack/memory/core.md` defines the baseline thinking and behavior standards loaded into every session. It covers:

- **Thinking quality**: Plan-before-act, reflect-after-result, diagnose-before-fix.
- **Workflow rules**: Classify intent, classify domain, delegate to specialists, test after changes.
- **Code quality**: No placeholder stubs, no restating comments, no decorative comments.
- **Anti-patterns**: Forbidden behaviors (asking "should I proceed?", chaining tools without reasoning).
- **Failure recovery**: Stop retrying after 3 identical failures, switch approach or delegate.

To adjust these defaults, edit `core.md` directly. Changes take effect in new sessions. The file is loaded via `@` import in `~/.claude/CLAUDE.md`, so no registration step is needed.

To add new defaults, append new sections or bullet points. To relax a rule, remove or soften the relevant line. The "anti-patterns" section uses `FORBIDDEN:` labels -- removing a label removes the hard enforcement.

---

## Statusline

The statusline is a Python script (`~/.claude/statusline.py`) that renders a two-line status bar showing:

- **Line 1**: Model name, working directory, git branch (with dirty indicator), active output style.
- **Line 2**: Context window usage bar (color-coded: green < 70%, yellow 70-89%, red >= 90%), usage percentage, session cost, session duration.

### Customizing the display

Edit `statusline.py` directly. The `main()` function assembles two lines from parsed JSON data:

- To change colors, modify the ANSI constants at the top of the file (`CYAN`, `YELLOW`, `GREEN`, etc.).
- To change the bar width, modify the `width` parameter in `make_bar()` (default: 18 characters).
- To add or remove fields, edit the `line_one_parts` or `line_two` assembly in `main()`.
- To change the context threshold colors, edit `bar_color()` (defaults: green < 70%, yellow 70-89%, red >= 90%).

The statusline is registered in `~/.claude/settings.json` under `statusLine`:

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/statusline.py",
  "padding": 0
}
```

Git information is cached for 5 seconds per working directory to avoid performance overhead from repeated `git` calls.

---

## Output Style

oh-my-claude ships with the **OpenCode Compact** output style (`~/.claude/output-styles/opencode-compact.md`). It produces compact, scan-friendly responses with clear hierarchy: answer first, then verification, then risk or next steps.

### Switching output styles

To use a different output style, either:

1. Replace the contents of `opencode-compact.md` with your preferred style definition.
2. Create a new style file in `~/.claude/output-styles/` and update `~/.claude/settings.json`:

```json
"outputStyle": "Your Style Name"
```

The style name must match the `name` field in the style file's frontmatter.

### Modifying the existing style

Edit `~/.claude/output-styles/opencode-compact.md`. The file defines presentation rules (lead with the answer, use headings), response shape (comparison tables, bold labels), and tone (direct, collaborative, no filler). Changes take effect in new sessions.

---

## Ghostty Theme

oh-my-claude includes a Ghostty terminal theme in `config/ghostty/themes/`. The installer copies the theme and a config snippet to the appropriate Ghostty directories.

To modify the theme:

1. Edit the theme file in `config/ghostty/themes/`.
2. Colors are defined as hex values in Ghostty's theme format.
3. Re-run `bash install.sh` to copy the updated theme, or edit the installed copy directly at `~/.config/ghostty/themes/`.

The config snippet (`config/ghostty/config.snippet.ini`) sets the active theme and any terminal-level settings. If you use a different terminal emulator, this component can be ignored.

---

## Updating oh-my-claude

To update to a newer version, pull the latest changes and re-run the installer:

```bash
cd /path/to/oh-my-claude
git pull
bash install.sh
```

Use the same flags you used on the original install (e.g., `--bypass-permissions`, `--model-tier=economy`). The model tier is persisted in `~/.claude/oh-my-claude.conf` and re-applied automatically, so you only need to pass `--model-tier` again if you want to change it.

### What happens on update

1. **Backup**: Every file that will be overwritten is copied to `~/.claude/backups/oh-my-claude-{TIMESTAMP}/`.
2. **Overwrite**: All agents, skills, hook scripts, output styles, statusline, and quality-pack memory files are replaced from the bundle via `rsync`.
3. **Merge**: `settings.json` is merged (user additions preserved, harness hooks updated).
4. **Re-apply**: Model tier is re-applied from `oh-my-claude.conf` if present.
5. **Verify**: Run `bash verify.sh` to confirm the update succeeded.

### What survives an update

- `settings.json` user additions (custom hooks, custom settings) -- merged, not overwritten.
- `~/.claude/oh-my-claude.conf` -- not in the bundle, never touched by rsync.
- Custom agent files you created (not shipped in the bundle) -- rsync adds files but does not delete extras.
- Custom skill directories you created -- same reason.

### What gets overwritten

All files that exist in the `bundle/dot-claude/` directory, including: agent definitions, skill definitions, hook scripts, `common.sh`, quality-pack memory files (`core.md`, `skills.md`, `compact.md`), `statusline.py`, output styles, and `CLAUDE.md`.

If you customized any bundled file, your changes are lost on update. The backup directory contains the previous version for manual recovery.

---

## Rollback and Recovery

Every install creates a timestamped backup at `~/.claude/backups/oh-my-claude-{TIMESTAMP}/`. This directory mirrors the structure of `~/.claude/` and contains every file that was overwritten, plus a copy of `settings.json`.

### Restore a single file

```bash
# Find the most recent backup
ls -t ~/.claude/backups/ | head -1

# Copy the file back
cp ~/.claude/backups/oh-my-claude-20260407-143000/agents/quality-planner.md ~/.claude/agents/quality-planner.md
```

### Full rollback

```bash
# Find the backup to restore from
BACKUP=~/.claude/backups/oh-my-claude-20260407-143000

# Copy everything back (preserves your current settings.json merge)
rsync -a "$BACKUP/" ~/.claude/ --exclude=settings.json

# Or include settings.json if you want the pre-update version
rsync -a "$BACKUP/" ~/.claude/
```

This restores backed-up files but does not remove files added by the new version. If the update introduced new agents or scripts, those will remain alongside the restored files.

### Recover settings.json

The backup always includes the pre-install `settings.json`:

```bash
cp ~/.claude/backups/oh-my-claude-20260407-143000/settings.json ~/.claude/settings.json
```

---

## Configuration Safety

Not all customizations carry the same risk. This matrix classifies files by how safe they are to edit and whether changes survive updates.

| Category | Files | Risk | Survives update? |
|---|---|---|---|
| **Safe, persistent** | `settings.json` (user-added hooks/settings) | Low | Yes (merged) |
| **Safe, persistent** | `oh-my-claude.conf` | Low | Yes (not in bundle) |
| **Safe, persistent** | Custom agents you create in `~/.claude/agents/` | Low | Yes (not in bundle) |
| **Safe, persistent** | Custom skills you create in `~/.claude/skills/` | Low | Yes (not in bundle) |
| **Safe, overwritten** | Agent `.md` files (model, maxTurns) | Low | No (re-apply or use `--model-tier`) |
| **Moderate, overwritten** | `quality-pack/memory/core.md` | Medium | No |
| **Moderate, overwritten** | `output-styles/opencode-compact.md` | Medium | No |
| **Moderate, overwritten** | `statusline.py` | Medium | No |
| **High risk, overwritten** | `skills/autowork/scripts/stop-guard.sh` | High | No |
| **High risk, overwritten** | `skills/autowork/scripts/common.sh` | High | No |
| **High risk, overwritten** | Other hook scripts in `skills/autowork/scripts/` | High | No |

**Rule of thumb**: If a file ships in `bundle/dot-claude/`, it will be overwritten on the next install. Prefer out-of-bundle customization (creating new agents, new skills, adding to `settings.json`) over modifying bundled files.

### AI-assisted configuration

You can ask Claude (or another AI assistant) to modify harness configuration. Some changes are safe; others can break the quality gate system.

**Safe for AI to edit:**
- `settings.json` -- adding custom hooks, changing `outputStyle` or `effortLevel`.
- `oh-my-claude.conf` -- changing model tier.
- Creating new agent files in `~/.claude/agents/`.
- Creating new skill directories in `~/.claude/skills/`.
- `quality-pack/memory/core.md` -- adjusting cognitive defaults, relaxing rules.

**Risky for AI to edit (understand before changing):**
- `stop-guard.sh` -- modifying quality gate logic can disable enforcement.
- `common.sh` -- changes affect all hooks (intent classification, domain scoring, state management).
- `prompt-intent-router.sh` -- changing intent routing can break the workflow loop.
- Intent classification order in `common.sh` -- the check order is a [protected design decision](architecture.md).

If you ask an AI agent to modify hook scripts, review the changes carefully before starting a new session. A broken hook script can cause silent failures (the harness stops enforcing without any visible error).
