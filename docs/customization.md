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

For quality and economy tiers, the script updates agent `model:` lines in-place via sed -- no full reinstall, no backup cycle. For the balanced tier, it restores bundle defaults from the saved repo path. The tier choice is persisted to `oh-my-claude.conf`.

| Tier | Opus agents | Sonnet agents | Best for |
|---|---|---|---|
| `quality` | All 23 | 0 | Users with high usage limits who prioritize quality over cost |
| `balanced` | 9 (planning, review, debugging, writing, operations) | 13 (execution, research, domain specialists) | Most users (default) |
| `economy` | 0 | All 23 | Users on tighter plans or budget-conscious API usage |

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

## Other install flags

**`--git-hooks`** — writes `.git/hooks/post-merge` into the source checkout so that every `git pull` (or any other merge) checks whether the bundle has drifted from the last install. When drift is detected, the hook prints a yellow `[oh-my-claude] Bundle changes detected after merge.` banner and prints the installer command. The hook is non-blocking — it never aborts the underlying git operation. Set `OMC_AUTO_INSTALL=1` in your environment to have the hook re-run `install.sh` automatically (useful for CI / trusted environments). `install.sh` never overwrites a pre-existing non-oh-my-claude hook at the same path; a foreign hook keeps the slot. `uninstall.sh` removes the hook only if it carries the `# oh-my-claude post-merge auto-sync` signature.

```bash
bash install.sh --git-hooks              # one-time opt-in during install
```

**`--no-ios`** — skip the 4 iOS-specific specialist agents (`ios-core-engineer`, `ios-ui-developer`, `ios-deployment-specialist`, `ios-ecosystem-integrator`) during install. The flag removes any `~/.claude/agents/ios-*.md` files; `frontend-developer` is unaffected even though it covers some web/native overlap. Saves ~15 KB in `~/.claude/agents/` and reduces `/agents` picker noise if you don't ship iOS.

```bash
bash install.sh --no-ios
```

---

## Bug reports with omc-repro

`~/.claude/omc-repro.sh` packages a session's state into a shareable tarball. User-prompt and assistant-message fields (`last_user_prompt`, `last_assistant_message`, `current_objective`, `last_meta_request` in session state; `prompt_preview` in classifier telemetry; `text` in recent_prompts) are truncated to 80 chars before bundling. Override with `OMC_REPRO_REDACT_CHARS`:

```bash
bash ~/.claude/omc-repro.sh                            # bundle the latest session
bash ~/.claude/omc-repro.sh --list                     # list recent sessions
bash ~/.claude/omc-repro.sh <session-id>               # bundle a specific session
OMC_REPRO_REDACT_CHARS=200 bash ~/.claude/omc-repro.sh # keep more context
```

The script never falls back to unredacted copies on jq failure — a corrupt row is dropped rather than leaked. Always review the bundle (`tar -xzf ~/omc-repro-*.tar.gz -C /tmp`) before sharing if you have additional privacy concerns.

---

## User-Override Layer

Files in `~/.claude/omc-user/` are **never overwritten** by `install.sh`. Use this directory for customizations that should survive updates.

The default template is `~/.claude/omc-user/overrides.md`, which is loaded after the bundle defaults via the `@` reference in `CLAUDE.md`. Anything you put here takes effect in every session.

### What to put in overrides.md

- **Custom anti-patterns**: `FORBIDDEN: [your rule]`
- **Relaxed rules**: `Override: when working on prototypes, skip the excellence-reviewer gate`
- **Domain-specific guidance**: `When working on [your project type], always [your preference]`
- **Specialist preferences**: `Prefer oracle over metis for debugging in this codebase`

### What NOT to put here

- Threshold tuning (stall detection, file counts) — use `~/.claude/oh-my-claude.conf` instead
- Model tier changes — use `bash ~/.claude/switch-tier.sh <tier>` instead

### The override is additive

`overrides.md` is loaded **after** the bundle's `core.md`, `skills.md`, and `compact.md`. Your rules supplement the defaults; they don't replace them. To override a specific default rule, explicitly state the override in your file.

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

  **Subagent-side budget, not parent-side.** Every subagent's output is hard-truncated to 1000 characters before it reaches the parent session -- see `skills/autowork/scripts/reflect-after-agent.sh:41`, which calls `truncate_chars 1000 "${message}"` when building the `finding_context` injection. The `maxTurns` cap only governs how many tool calls a subagent can make during its own investigation; a higher cap does *not* expand the amount of subagent output that lands in the parent conversation. In other words, raising `maxTurns` costs subagent compute time and API spend but has **zero parent-context cost**. The 1.1.0 rationale for lowering reviewer caps ("to limit context bloat") did not hold once this boundary was accounted for.

  **Rule of thumb for new agents:** size `maxTurns` to the agent's investigative scope, not to a parent-context budget. Deep investigators (reviewers that read every changed file, debuggers tracing multi-file bugs, researchers surveying a codebase) warrant 25-30+. Quick extractors and single-question helpers can stay at 12-18. When in doubt, err high -- truncated reviews are expensive in rework, and the injection boundary makes a larger subagent budget cheap in context.
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

The stop guard (`skills/autowork/scripts/stop-guard.sh`) enforces five independent gates: advisory inspection, session handoff, review/verification, dimension gate (prescribed reviewer sequence), and excellence review. Each has a block limit that caps how many times it can prevent Claude from stopping.

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

### Configurable thresholds

Several configurable thresholds can be tuned via `~/.claude/oh-my-claude.conf` without editing hook scripts:

| Key | Default | What it controls |
|-----|---------|-----------------|
| `stall_threshold` | `12` | Consecutive Read/Grep calls before stall detection fires |
| `excellence_file_count` | `3` | Unique edited files that trigger the excellence review gate |
| `dimension_gate_file_count` | `3` | Unique edited files that trigger the prescribed-sequence dimension gate. Set to a high value (e.g. 100) to effectively disable the dimension gate. |
| `traceability_file_count` | `6` | Unique edited files above which the dimension gate additionally requires `briefing-analyst` for traceability. |
| `state_ttl_days` | `7` | Days before stale session state directories are swept |
| `verify_confidence_threshold` | `40` | Minimum verification confidence (0-100) to pass the quality gate |
| `custom_verify_mcp_tools` | _(empty)_ | Pipe-separated glob patterns for additional MCP tools that count as verification (e.g. `mcp__my_cypress__*`). Also requires a matching PostToolUse hook entry in `settings.json`. |
| `installation_drift_check` | `true` | When `true`, the statusline appends a yellow `↑v<repo>` segment whenever `${repo_path}/VERSION` is newer than the bundled `installed_version` (semver-aware; deliberate downgrades do not trigger). Surfaces the "I pulled but forgot to re-run `install.sh`" case. Requires `repo_path` to be present in the conf — `install.sh` writes it on every install. Local-only check; no network. Set to `false` to suppress the indicator. |
| `pretool_intent_guard` | `true` | When `true`, the PreToolUse `pretool-intent-guard.sh` hook denies destructive git/gh commands (commit, push, revert, reset --hard, rebase, branch -D, gh pr create, etc.) while `task_intent` is `advisory`, `session_management`, or `checkpoint`. Closes the 2026-04-17 regression where an advisory prompt followed by a compact could result in unauthorized commits. Set to `false` to disable enforcement and rely on the directive layer alone (e.g. if the classifier's advisory detection over-fires in your workflow). See `docs/compact-intent-preservation.md`. |
| `classifier_telemetry` | `on` | When `on`, `prompt-intent-router.sh` writes a per-turn row `{ts, intent, domain, prompt_preview (200 chars), pretool_blocks_observed}` to `<session>/classifier_telemetry.jsonl` and the next prompt's hook may annotate misfire rows when a PreTool block fired under a non-execution classification. Set to `off` to disable all recording — useful for shared machines, regulated codebases, or any workflow where writing user prompt previews to disk is unwanted. With `off`, `/ulw-status --classifier` has nothing to show and the cross-session `classifier_misfires.jsonl` is not populated. |
| `gate_level` | `full` | Enforcement depth for the stop-guard quality gates. `full` (default) enables all gates including review coverage and excellence; `standard` enables quality + excellence gates; `basic` enables only the quality gate. Lower this on prototypes or solo branches where the full sequence is overhead. Env: `OMC_GATE_LEVEL`. |
| `guard_exhaustion_mode` | `scorecard` | Behavior when a gate's block cap is reached. `scorecard` (default) emits a quality scorecard then releases the stop; `block` keeps blocking; `silent` releases without output. Legacy aliases accepted: `warn` → `scorecard`, `strict` → `block`, `release` → `silent`. Env: `OMC_GUARD_EXHAUSTION_MODE`. |
| `discovered_scope` | `on` | When `on`, advisory-specialist findings (council lenses, `metis`, `briefing-analyst`) are captured to `<session>/discovered_scope.jsonl` and the stop-guard blocks until pending rows are addressed under execution intent. Block cap is 2 by default; raised to `N+1` when a Council Phase 8 wave plan with `N` waves is active, so the gate stays useful across legitimate wave-by-wave commits. Set to `off` as a kill switch when heuristic extraction is too noisy on a project's prose style. Env: `OMC_DISCOVERED_SCOPE`. |
| `council_deep_default` | `off` | When `on`, auto-triggered council dispatches (broad project-evaluation prompts under `/ulw` that match `is_council_evaluation_request`) inherit `--deep` behavior — each lens uses `model: opus` instead of the default `sonnet`. Explicit `/council --deep` always escalates regardless of this flag; explicit `/council` (no flag) is unaffected. The router also honors an inline `--deep` token in the prompt text (e.g. `/ulw evaluate the project --deep`) independently of this conf flag. Cost: meaningfully higher per auto-triggered run — leave `off` unless you want every auto-detected council to be opus-grade. Env: `OMC_COUNCIL_DEEP_DEFAULT`. |
| `auto_memory` | `on` | When `on`, the auto-memory wrap-up rule (`memory/auto-memory.md`) and compact-time memory sweep (`memory/compact.md`) write `project_*.md`, `feedback_*.md`, `user_*.md`, and `reference_*.md` files into your `memory/` directory at session-stop and pre-compact moments. Set to `off` for shared machines, regulated codebases, or projects where session memory should not accrue across runs. Explicit user requests ("remember that...", "save this as memory") still apply regardless. Helper: `is_auto_memory_enabled()` in `common.sh`. Env: `OMC_AUTO_MEMORY`. |

Example `~/.claude/oh-my-claude.conf`:

```
stall_threshold=20
excellence_file_count=5
dimension_gate_file_count=5
traceability_file_count=10
state_ttl_days=14
verify_confidence_threshold=40
installation_drift_check=true
```

Values can also be overridden via environment variables (`OMC_STALL_THRESHOLD`, `OMC_EXCELLENCE_FILE_COUNT`, `OMC_DIMENSION_GATE_FILE_COUNT`, `OMC_TRACEABILITY_FILE_COUNT`, `OMC_STATE_TTL_DAYS`, `OMC_VERIFY_CONFIDENCE_THRESHOLD`, `OMC_CUSTOM_VERIFY_MCP_TOOLS`, `OMC_INSTALLATION_DRIFT_CHECK`, `OMC_PRETOOL_INTENT_GUARD`). Environment variables take precedence over the conf file, and both override the built-in defaults. `OMC_REPRO_REDACT_CHARS` (default `80`) is env-only and controls the truncation length applied by `~/.claude/omc-repro.sh`.

### Recipe: shell-only / lint-as-tests projects

For projects where the primary automated check is a linter — pure-bash utilities, config-only repositories, spec-only documentation packages — the default `verify_confidence_threshold=40` can block legitimate stop attempts because `bash -n` and `shellcheck` score `30`. Rather than lowering the threshold globally (which weakens verification for every project), use per-project configuration to scope the override:

```bash
# From inside the project root:
mkdir -p .claude
cat > .claude/oh-my-claude.conf <<'EOF'
# Pure-bash project — lint IS the test. Relax the verification floor
# from 40 to 30 so shellcheck and bash -n can satisfy the quality gate.
verify_confidence_threshold=30
EOF
```

The harness walks up from `$PWD` looking for `.claude/oh-my-claude.conf`, so this override applies only when Claude Code is invoked from this project. The user-level `~/.claude/oh-my-claude.conf` keeps the `40` default for every other repo, and the existing `custom_verify_patterns` mechanism still lets you register project-specific test wrappers:

```
# Also in .claude/oh-my-claude.conf — name a wrapper script so the gate
# can recognize it as a higher-confidence project test command.
custom_verify_patterns=\b(run-tests\.sh|check\.sh)\b
```

If you later add an actual test suite, drop the threshold override and let the higher-confidence verification path satisfy the default gate.

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

- **Line 1**: Model name, working directory, ULW mode indicator (when active), git branch (with dirty indicator), active output style.
- **Line 2**: Context window usage bar (color-coded: green < 70%, yellow 70-89%, red >= 90%), usage percentage, input/output token counts, session cost (with `*` when ULW active to signal subagent costs are excluded), session duration. Conditionally appends: rate limit usage (`RL:%`), prompt cache hit ratio (`C:%`), and API latency ratio (`API:%`) when data is available.

### Customizing the display

Edit `statusline.py` directly. The `main()` function assembles two lines from parsed JSON data:

- To change colors, modify the ANSI constants at the top of the file (`CYAN`, `YELLOW`, `GREEN`, etc.).
- To change the bar width, modify the `width` parameter in `make_bar()` (default: 18 characters).
- To add or remove fields, edit the `line_one_parts` or `line_two_parts` assembly in `main()`.
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
