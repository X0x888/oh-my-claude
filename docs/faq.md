# FAQ

### What's the difference between /ulw and just typing ulw?

Both work. The prompt-intent-router checks for the keyword `ulw` (along with `autowork`, `ultrawork`, and `sisyphus`) anywhere in the prompt text using a case-insensitive regex match. The leading slash is a Claude Code skill invocation convention, but the harness activates on the keyword itself regardless of whether the slash is present.

### How is this different from oh-my-claudecode?

oh-my-claudecode is a Node.js/TypeScript plugin framework for extending Claude Code. oh-my-claude is a pure bash harness with zero npm dependencies. The key structural differences: oh-my-claude enforces quality through hard stop gates (Claude literally cannot finish until review and verification are done), classifies every prompt by intent and domain before acting, routes work to specialist agents across multiple domains (not just coding), and preserves session state through compaction. oh-my-claudecode focuses on extensibility; oh-my-claude focuses on cognitive quality enforcement.

### Does this work with Claude Code plugins?

Yes. oh-my-claude operates through Claude Code's built-in hooks system (`settings.json`), not through a plugin framework. Hooks and plugins occupy different extension points and do not conflict. If you have plugins installed, they continue to work alongside the harness.

### What happens if I already have custom hooks?

The installer merges hook entries from `settings.patch.json` into your existing `settings.json`. If you already have hooks registered for the same events (UserPromptSubmit, Stop, PostToolUse, etc.), the installer adds the harness hooks alongside yours. Multiple hooks on the same event run in the order they appear in the array. Review your `~/.claude/settings.json` after installation to confirm the merge looks correct.

### Can I use this with a different output style?

Yes. The output style is configured in `~/.claude/settings.json` under the `outputStyle` key and defined in `~/.claude/output-styles/`. You can replace the bundled OpenCode Compact style with any style definition, or create a new style file and point `outputStyle` to its name. The harness hooks do not depend on the output style.

### How do I disable a specific quality gate?

Edit `~/.claude/skills/autowork/scripts/stop-guard.sh`. Each gate is an independent conditional block. To disable one, either set its block cap to `0` (e.g., change `-lt 2` to `-lt 0`) or remove the block entirely. To disable all quality gates at once, clear the Stop hook array in `~/.claude/settings.json`: `"Stop": []`.

### What does "ultrathink" do?

Adding `ultrathink` to any prompt injects a deeper investigation directive. It tells Claude to favor verification over abstraction: read actual files instead of reasoning about their probable contents, check claims against real code, run tests, and investigate further when evidence is ambiguous. It is designed for hard problems where unverified assumptions produce wrong answers. It does not change the domain or intent classification.

### Why do agents have disallowedTools?

Agent permission boundaries are a safety mechanism. Specialist agents (reviewers, researchers, analysts, planners) can read, search, and reason -- but they cannot edit files. The `disallowedTools: Write, Edit, MultiEdit` setting ensures the main thread retains exclusive control over all file mutations. This prevents unsupervised writes from agents that may be operating on incomplete context, and keeps the main thread as the single source of truth for changes.

### How does session continuity work?

Two hook pairs handle continuity. Before compaction, `pre-compact-snapshot.sh` writes the current objective, domain, intent, specialist conclusions, edited files, and review status to a snapshot file. After compaction, `session-start-compact-handoff.sh` reads that snapshot and injects it as context. For session resume (continuing a previous transcript), `session-start-resume-handoff.sh` copies the entire state directory from the prior session and injects the preserved context. In both cases, Claude picks up from the saved state rather than reconstructing from scratch.

### What is the intent classification system?

Every prompt is classified into one of five intent categories before Claude acts on it: execution (do this work), continuation (resume prior work), advisory (answer a question), checkpoint (pause cleanly), or session management (advise on session strategy). The classification determines how Claude handles the prompt -- advisory prompts are answered directly without forcing implementation, continuations preserve the prior objective, checkpoints allow clean stops. The classification runs in `classify_task_intent()` in `common.sh`, and the order of checks matters (see [architecture.md](architecture.md) for details).

### How do I add a new domain?

Edit `infer_domain()` in `~/.claude/skills/autowork/scripts/common.sh`. Add a new keyword-count variable (e.g., `devops_score`), define its regex pattern, and add it to the max-score comparison logic. Then add a corresponding `case` branch in `prompt-intent-router.sh` (inside the domain-specific specialist hints section) to define what context gets injected when that domain is detected. Finally, update the stop guard's domain-specific logic if the new domain should require verification.

### How do I update oh-my-claude?

Pull the latest changes from the repository and re-run the installer: `cd /path/to/oh-my-claude && git pull && bash install.sh`. Use the same flags as your original install. Your model tier preference is saved in `~/.claude/oh-my-claude.conf` and re-applied automatically. See [customization.md](customization.md#updating-oh-my-claude) for full details.

### Will updating overwrite my changes?

Yes, for any file that ships in the `bundle/dot-claude/` directory. This includes all agent definitions, skill definitions, hook scripts, quality-pack memory files, statusline, and output styles. Your `settings.json` is merged (user additions preserved), and custom agents/skills you created outside the bundle are not touched. Every install creates a timestamped backup at `~/.claude/backups/oh-my-claude-{TIMESTAMP}/` so you can recover overwritten files. See the [configuration safety matrix](customization.md#configuration-safety) for details on what survives.

### How do I change which model agents use?

The fastest way is the convenience script installed at `~/.claude/switch-tier.sh`:

```bash
bash ~/.claude/switch-tier.sh quality    # all Opus
bash ~/.claude/switch-tier.sh balanced   # default split
bash ~/.claude/switch-tier.sh economy    # all Sonnet
bash ~/.claude/switch-tier.sh            # show current tier
```

This reads your saved repo path and re-runs the installer with the new tier. You can also run the installer directly: `bash install.sh --model-tier=economy`. The choice is saved and re-applied on future installs. For per-agent control, edit individual agent files in `~/.claude/agents/` after installation. See [customization.md](customization.md#model-tiers) for details.

### Can I ask Claude to modify the harness?

Yes, with care. It is safe to ask an AI agent to edit `settings.json`, `oh-my-claude.conf`, create new agents, create new skills, or adjust `core.md`. It is risky to have it modify hook scripts (`stop-guard.sh`, `common.sh`, `prompt-intent-router.sh`) because a broken hook silently disables quality enforcement. If you do ask for hook script changes, review them carefully. See [configuration safety](customization.md#configuration-safety) for the full risk matrix.

### How do I recover from a bad install or update?

Every install creates a backup at `~/.claude/backups/oh-my-claude-{TIMESTAMP}/`. To restore a single file: `cp ~/.claude/backups/oh-my-claude-{TIMESTAMP}/path/to/file ~/.claude/path/to/file`. For a full rollback: `rsync -a ~/.claude/backups/oh-my-claude-{TIMESTAMP}/ ~/.claude/`. To completely remove oh-my-claude: `bash uninstall.sh`.

### Does this work on Linux?

Yes. The harness is pure bash and jq with no platform-specific dependencies. It runs anywhere Claude Code runs. The only macOS-specific component is the Ghostty terminal theme, which is optional and can be ignored on systems using other terminal emulators. The `statusline.py` script uses standard Python 3 with no external packages.
