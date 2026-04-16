# FAQ

### Which skill should I use?

Use this decision tree:

1. **"I need to get real work done."** → `/ulw <task>` (or `/autowork`). This is the default for any non-trivial task — coding, writing, research, or operations. It handles intent classification, domain routing, specialist agents, and quality gates automatically.

2. **"I need a plan before I start coding."**
   - Goal is clear and scoped → `/plan-hard <task>` — produces a decision-complete plan without editing files.
   - Goal is broad, vague, or ambiguous → `/prometheus <goal>` — runs an interview-first clarification process before planning.

3. **"I have a plan and want to check it for risks."** → `/metis <plan>` — stress-tests for hidden assumptions, missing constraints, and weak validation.

4. **"I need to understand existing code or context."** → `/research-hard <topic>` — gathers repo context, API wiring, and integration points.

5. **"I need official docs or external references."** → `/librarian <topic>` — fetches authoritative documentation, third-party API references, and concrete examples.

6. **"I'm stuck debugging or can't decide between approaches."** → `/oracle <issue>` — provides a deep debugging or architecture second opinion.

7. **"I want a code review."** → `/review-hard [focus]` — findings-first review of the current worktree or a specific area.

8. **"I'm setting up a new repo for Claude Code."** → `/atlas [focus]` — bootstraps or refreshes CLAUDE.md / .claude/rules.

9. **"I want to see what's happening."** → `/ulw-status` (session state) or `/skills` (list all skills).

10. **"I want to turn off ultrawork mode."** → `/ulw-off` — deactivates quality gates and domain routing for the rest of the session.

**Rule of thumb:** If you're unsure, start with `/ulw`. It auto-detects the domain and routes to the right specialists.

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

Edit `~/.claude/skills/autowork/scripts/stop-guard.sh`. Each gate is an independent conditional block. To disable one, either set its block cap to `0` (e.g., change `-ge 3` to `-ge 0`) or remove the block entirely. To disable all quality gates at once, clear the Stop hook array in `~/.claude/settings.json`: `"Stop": []`.

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

For the quality and economy tiers, the script updates agent files in-place without re-running the full installer. For the balanced tier, it restores bundle defaults from the repo. The choice is saved to `oh-my-claude.conf` and re-applied on future installs. For per-agent control, edit individual agent files in `~/.claude/agents/` after installation. See [customization.md](customization.md#model-tiers) for details.

### Can I ask Claude to modify the harness?

Yes, with care. It is safe to ask an AI agent to edit `settings.json`, `oh-my-claude.conf`, create new agents, create new skills, or adjust `core.md`. It is risky to have it modify hook scripts (`stop-guard.sh`, `common.sh`, `prompt-intent-router.sh`) because a broken hook silently disables quality enforcement. If you do ask for hook script changes, review them carefully. See [configuration safety](customization.md#configuration-safety) for the full risk matrix.

### How do I recover from a bad install or update?

Every install creates a backup at `~/.claude/backups/oh-my-claude-{TIMESTAMP}/`. To restore a single file: `cp ~/.claude/backups/oh-my-claude-{TIMESTAMP}/path/to/file ~/.claude/path/to/file`. For a full rollback: `rsync -a ~/.claude/backups/oh-my-claude-{TIMESTAMP}/ ~/.claude/`. To completely remove oh-my-claude: `bash uninstall.sh`.

### My custom test command isn't recognized as verification

The stop guard recognizes common test commands (`npm test`, `pytest`, `cargo test`, etc.) by pattern matching. If you use a custom test command like `bash run-tests.sh` or `./check.sh`, add your pattern to `~/.claude/oh-my-claude.conf`:

```
custom_verify_patterns=\b(run-tests\.sh|check\.sh)\b
```

The value is an extended regex appended to the built-in pattern with `|`. Multiple patterns can be combined: `\b(run-tests\.sh)\b|\b(make check)\b`.

### How do I debug hook execution?

Enable hook logging by adding `hook_debug=true` to `~/.claude/oh-my-claude.conf`:

```
hook_debug=true
```

Or set the environment variable `HOOK_DEBUG=1` before launching Claude Code. When enabled, hooks write timestamped entries to `~/.claude/quality-pack/state/hooks.log`. Entries show which hook fired, the classified intent/domain, and guard decisions.

### How do I deactivate ultrawork mode mid-session?

Run `/ulw-off`. This clears the workflow state and removes the ULW sentinel. Quality gates stop firing and domain routing turns off. The conversation continues normally -- only the ultrawork enforcement layer is disabled.

### Does this work on Linux?

Yes. The harness is pure bash and jq with no platform-specific dependencies. It runs anywhere Claude Code runs. The only macOS-specific component is the Ghostty terminal theme, which is optional and can be ignored on systems using other terminal emulators. The `statusline.py` script uses standard Python 3 with no external packages.

### A subagent returned only a few words ending in a colon, with no structured report — what happened?

The agent hit context exhaustion mid-generation. Claude Code sub-agents have their own context budget; when a prompt asks a single agent to cover many check categories across many files, the agent can run 30–40+ tool calls before trying to compose its final report, and there may not be enough headroom left to finish. The tool result "leaks" the last partial text block — usually ending with a trailing colon because the model was about to start its next sentence. Re-dispatch with a narrower scope: a specific file list, an explicit output-size cap (e.g. "respond in ≤250 words"), and a structured output template. This is covered by the *Right-size agent prompts* rule in `core.md`; the main thread should not try to infer findings from a truncated preamble.

### My live harness seems behind the latest release — how do I tell, and how do I fix it?

The installer does not auto-upgrade. After pulling the repo you must re-run `bash install.sh` to sync `~/.claude/` with the new bundle. Quick diagnostic (run from the repo root):

```bash
cd /path/to/oh-my-claude
diff -rq bundle/dot-claude ~/.claude 2>/dev/null | grep -v "^Only in /Users" | head
```

Files listed as `differ` mean the live harness and the bundled release diverge — typically because you pulled but didn't re-install. Another symptom: `bash verify.sh` reports an older `Version:` than `cat VERSION`. Fix: `git pull && bash install.sh`. Your `settings.json` merges, `omc-user/overrides.md`, and custom agents/skills outside the bundle are preserved; bundled files get overwritten and a timestamped backup is created under `~/.claude/backups/`.

### The "historical defect patterns" watch list shows inflated counts from older sessions — can I reset it?

Yes. Cross-session defect telemetry lives at `~/.claude/quality-pack/defect-patterns.json`. Older versions of `record-reviewer.sh` inflated categories like `missing_test`, `unknown`, and `security` by classifying reviewer narration prose instead of structured findings — see the *Fixed* section of the [CHANGELOG](../CHANGELOG.md) for the specific release that narrowed the classifier. If the injected watch list still shows those old counts, you can reset without losing session state:

```bash
rm -f ~/.claude/quality-pack/defect-patterns.json
```

Same pattern for agent performance telemetry: `rm -f ~/.claude/quality-pack/agent-metrics.json`. Both files are rebuilt from scratch on the next session that triggers a write. Session state (`~/.claude/quality-pack/state/`) is independent and is not touched by this reset.
