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
