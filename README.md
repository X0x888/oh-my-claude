# oh-my-claude

**What if Claude Code couldn't cut corners?**

[![Version](https://img.shields.io/badge/Version-1.11.1-blue.svg)](CHANGELOG.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-bash-green.svg)]()
[![Dependencies](https://img.shields.io/badge/Dependencies-none-brightgreen.svg)]()

A cognitive quality harness for Claude Code. Bash hooks, skills, and specialist agents that enforce thinking, testing, and review as structural requirements -- not suggestions.

> **Specialist agents activate automatically based on your task.** You don't need to learn agent names -- just describe what you want to accomplish, and `/ulw` handles the rest.

---

## Quick start

```bash
git clone https://github.com/X0x888/oh-my-claude.git
cd oh-my-claude
bash install.sh --bypass-permissions   # recommended for power users
# Or: bash install.sh                  # standard install — permission prompts kept
# Restart Claude Code, then:
bash verify.sh
```

`--bypass-permissions` turns off Claude Code's built-in "allow this tool?" prompts so `/ulw` can run uninterrupted. Quality gates still apply — this flag only affects Claude Code's confirmations, not the harness's reviewers or verification. Leave it off if you'd rather approve each tool invocation.

**First time?** Run `/ulw-demo` to see the quality gates in action before starting real work.

Then jump into real work:

```
/ulw fix the failing test and add regression coverage
```

**Already installed?** Pull + re-install to pick up new releases — `install.sh` overwrites the bundled hooks, agents, skills, and memory files in `~/.claude/` but preserves your `settings.json` merges, `omc-user/overrides.md`, and any custom agents or skills whose names are outside the bundle (a user-created `oracle.md` *would* get overwritten because `oracle.md` is bundled; `my-reviewer.md` would not):

```bash
cd /path/to/oh-my-claude
git pull && bash install.sh
```

Your model tier preference is saved in `~/.claude/oh-my-claude.conf` and re-applied automatically. When the source repo is ahead of the installed bundle, the statusline shows a yellow `↑v<version>` arrow — re-run `install.sh` to sync. See the FAQ entries [*How do I update oh-my-claude?*](docs/faq.md#how-do-i-update-oh-my-claude) and [*Will updating overwrite my changes?*](docs/faq.md#will-updating-overwrite-my-changes) for the full safety matrix.

![oh-my-claude /ulw-demo — quality gates in action](docs/ulw-demo.gif)

---

## The problem

Claude Code is powerful, but out of the box it cuts corners in predictable ways:

- **It writes code but doesn't test it.** You get a diff that looks right, breaks in practice, and you're the one who finds out.
- **It stops before work is actually done.** "I've made the changes" -- but there's no review, no verification, no evidence it works.
- **It defers unfinished work to "a future session."** Wave 1 done, Wave 2 is next. Except Wave 2 never happens.
- **It gives surface-level advice without reading actual code.** Generic patterns instead of grounded analysis of what's in front of it.
- **It chains tool calls without thinking between them.** Mechanical sequences that look productive but skip the reasoning that catches mistakes.
- **It only works well for coding.** Ask it to write a proposal, research a decision, or plan an initiative and it falls back to code-shaped workflows.

These aren't edge cases. They're the daily experience of anyone using Claude Code for real work.

## What oh-my-claude does

oh-my-claude enforces cognitive quality through structure, not prompt engineering. Instead of asking Claude to please think harder, it installs bash hooks that intercept Claude Code's lifecycle events -- prompt submission, session compaction, stop attempts -- and injects domain-aware context, quality requirements, and hard gates that Claude cannot bypass.

The result: Claude classifies your intent before acting, routes work to specialist agents, thinks between tool calls, and literally cannot mark a task as done until review and verification are complete.

## Feature highlights

### Hard quality gates

Stop event blocking prevents Claude from finishing until testing and review are done. Wrote code but didn't run the tests? Blocked. Made edits but skipped the reviewer? Blocked. Deferred work to a "future session" without a checkpoint? Blocked. Edited 3+ files but skipped the excellence review? Blocked. Caps on each gate prevent infinite loops -- if Claude can't satisfy the gates, it surfaces the gap instead of spinning.

### Prescribed reviewer sequence

On complex tasks (3+ edited files by default), the stop-hook stops guessing which reviewer to run next and prescribes the sequence. Each reviewer owns one distinct dimension:

- `quality-reviewer` — bug hunt, code quality
- `design-reviewer` — design quality (auto-activates when UI files edited)
- `metis` — stress-test hidden assumptions
- `excellence-reviewer` — completeness against the original objective
- `editor-critic` — doc clarity and accuracy
- `briefing-analyst` — traceability (kicks in at 6+ files)

Each gate block message names the specific next reviewer. A `VERDICT: CLEAN|SHIP|FINDINGS (N)` line in each reviewer's output tells the hook whether the dimension was ticked. Doc-only edits route straight to `editor-critic` and skip the code-verification gate, so fixing a typo in CHANGELOG doesn't re-trigger `npm test`.

### Intent classification

A bash state machine classifies every prompt into one of 5 intent categories -- execution, continuation, advisory, checkpoint, or session-management -- crossed with 6 domain types: coding, writing, research, operations, mixed, and general. Claude knows *what you're asking* and *what domain you're in* before it takes a single action. Advisory questions get answered directly; execution prompts get the full specialist pipeline.

### Multi-domain routing

oh-my-claude is not a coding tool that happens to accept prose. Each domain has its own specialist chain:

- **Coding** -- quality-planner for scoping, quality-researcher for context, specialist developers (frontend, backend, fullstack, iOS, DevOps, test), quality-reviewer and excellence-reviewer for verification
- **Writing** -- writing-architect for structure, draft-writer for content, editor-critic for polish
- **Research** -- librarian for source gathering, briefing-analyst for synthesis, metis for stress-testing conclusions
- **Operations** -- chief-of-staff turns vague asks into structured deliverables, action plans, and decision memos

### Session continuity

Pre- and post-compact hooks snapshot the working state when Claude Code compacts a session. Objectives, domain classification, accepted decisions, specialist conclusions, in-flight specialist dispatches, pending review obligations, and task progress all survive compaction. When the session resumes, context is rehydrated -- not reconstructed from scratch.

### Permissioned agents

30 specialist agents, each with `disallowedTools` enforced. Agents can read, search, analyze, and plan -- but they cannot edit files. The main thread owns all mutations. This means agents provide high-quality analysis without unsupervised writes, and the main thread remains the single source of truth for code changes.

### Project Council

The `/council` skill dispatches a multi-role evaluation panel that inspects your project from the perspectives a full product team would bring: Product Manager, UX Designer, Security Engineer, Data/Analytics Lead, SRE, and Growth Lead. Each role-lens agent evaluates independently with a non-overlapping mandate, and findings are synthesized into a single prioritized assessment. The system auto-detects broad evaluation prompts like "evaluate my project" under `/ulw` and triggers the council flow automatically. Solo developers get the cross-functional perspective that a full team provides through daily friction -- without the team.

### Zero dependencies

No npm. No TypeScript. No Node.js runtime. No plugin framework. The entire harness is bash scripts and jq. It works anywhere Claude Code runs, installs in seconds, and leaves no footprint beyond the `~/.claude/` directory.

---

## AI-assisted install

Already in Claude Code? Paste one of these prompts directly.

**First-time install:**

> Clone https://github.com/X0x888/oh-my-claude.git into ~/repos/ and run its install.sh. Ask me which model tier I want (quality for all-Opus, balanced for the default mix, or economy for all-Sonnet) and whether I want bypass-permissions mode. Run verify.sh after installing and report the results.

**Update an existing install:**

> Update my oh-my-claude installation. The repo path is saved in ~/.claude/oh-my-claude.conf under repo_path. Pull the latest changes, re-run install.sh, then run verify.sh and tell me what changed.

## Usage examples

**Coding**
```
/ulw debug why settings saves but shows stale data until refresh
```

**Writing**
```
ulw draft a project proposal for an AI-assisted research workflow
```

**Research**
```
/ulw compare server-session auth vs JWT and recommend one
```

**Operations**
```
ulw turn these meeting notes into an action plan and follow-up email
```

**Project evaluation**
```
/council
/ulw evaluate my project and plan for improvements
```

---

## How it works

When you submit a prompt, the intent router (`prompt-intent-router.sh`) classifies it by intent category and domain, then injects the appropriate context and specialist instructions into Claude's working memory. Claude processes the task using the routed specialist agents -- each scoped to its domain and constrained by permission boundaries. When Claude attempts to stop, the stop guard (`stop-guard.sh`) checks whether review and verification obligations are met. If they aren't, the stop is blocked and Claude is told exactly what's missing.

The core state machine (`common.sh`) handles intent classification, domain scoring, session state tracking, and the quality gate logic. All state is managed in bash -- no external services, no databases, no background processes.

For the full architecture, see [docs/architecture.md](docs/architecture.md).

## Comparison

| | Vanilla Claude Code | oh-my-claudecode | oh-my-claude |
|---|---|---|---|
| **Quality enforcement** | None | None | Hard stop gates |
| **Intent classification** | None | None | 5-category state machine |
| **Domain coverage** | Code-only | Code-focused | Coding, writing, research, ops |
| **Dependencies** | -- | Node.js, TypeScript | bash + jq |
| **Agent safety** | Unrestricted | Varies | disallowedTools enforced |
| **Session continuity** | Lost on compaction | Varies | Pre/post-compact hooks |
| **Architecture** | Monolithic | Plugin/orchestration | Harness hooks |

---

## Repository structure

```
oh-my-claude/
├── install.sh / uninstall.sh / verify.sh   # Install, remove, and verify
├── bundle/dot-claude/                       # Installs to ~/.claude/
│   ├── agents/          (30 agents)         # Specialist agent definitions
│   ├── skills/          (17 skills)         # Skill definitions + autowork hooks
│   ├── quality-pack/                        # Lifecycle hooks + memory files
│   ├── output-styles/                       # Output format templates
│   └── statusline.py                        # Custom statusline widget
├── config/settings.patch.json               # Merged into user settings on install
├── tests/               (17 bash + 1 py)    # Intent, quality gates, stall, resume, e2e, install/uninstall merge, concurrency, post-merge, repro redaction, discovered-scope, finding-list, state-io, classifier-replay, serendipity-log, statusline
├── tools/                                    # Developer-only tools (replay-classifier-telemetry.sh, classifier-fixtures/)
└── docs/                                    # Architecture, customization, FAQ, prompts
```

> **Why `dot-claude` instead of `.claude`?** Claude Code's permission system treats paths containing `.claude/` as sensitive, triggering prompts on every edit during development. The installer copies `bundle/dot-claude/` into `~/.claude/` on your machine. This is the same pattern used by oh-my-zsh, chezmoi, etc.

### Available skills

Skills are invoked as slash commands or routed automatically by the intent classifier.

| Skill | Command | Purpose |
|-------|---------|---------|
| ulw | `/ulw <task>` | Maximum-autonomy professional workflow |
| plan-hard | `/plan-hard <task>` | Decision-complete planning without edits |
| review-hard | `/review-hard [focus]` | Findings-first code review |
| research-hard | `/research-hard <topic>` | Targeted context gathering |
| prometheus | `/prometheus <goal>` | Interview-first planning for ambiguous work |
| metis | `/metis <plan>` | Stress-test plans for hidden risks |
| oracle | `/oracle <issue>` | Deep debugging second opinion |
| librarian | `/librarian <topic>` | Official docs and reference research |
| frontend-design | `/frontend-design <task>` | Distinctive design-first frontend work |
| atlas | `/atlas [focus]` | Bootstrap or refresh repo instruction files |
| council | `/council [focus] [--deep]` | Multi-role project evaluation with top-finding verification, then **Phase 8** wave-by-wave execution when fixes are requested ("implement all", "exhaustive", "fix everything"). `--deep` escalates lenses to opus. |
| ulw-demo | `/ulw-demo` | Guided onboarding walkthrough with real quality gates |
| ulw-skip | `/ulw-skip <reason>` | Skip current quality gate block once |
| ulw-status | `/ulw-status` | Show current session state and Council Phase 8 wave-plan progress (debugging). `summary` / `classifier` arguments swap modes. |
| ulw-off | `/ulw-off` | Deactivate ultrawork mode mid-session |
| skills | `/skills` | List all available skills with usage guide |

> Aliases `/autowork`, `/ultrawork`, and `sisyphus` also trigger the ulw workflow.

## Power-user setup

For maximum autonomy, install with permission bypass:

```bash
bash install.sh --bypass-permissions
```

This skips all Claude Code permission prompts, letting the harness run without interruption. The quality gates still apply -- bypass-permissions affects Claude Code's built-in confirmations, not the harness's review and verification requirements. Use this if you trust the harness and want uninterrupted flow.

Other install options:

```bash
bash install.sh --no-ios                # Skip iOS-specific agents
bash install.sh --model-tier=economy    # All agents use Sonnet (cheaper)
bash install.sh --model-tier=quality    # All agents use Opus (max quality)
bash install.sh --git-hooks             # Install .git/hooks/post-merge auto-sync prompt
bash ~/.claude/switch-tier.sh economy   # Switch tier post-install (from anywhere)
bash uninstall.sh                       # Cleanly remove the harness
```

`--git-hooks` installs a `post-merge` hook inside this repo's `.git/hooks/`
that detects when `git pull` brings in bundle changes and reminds you to
re-run `install.sh`. Set `OMC_AUTO_INSTALL=1` when merging to run the
installer automatically. The hook never overwrites a pre-existing non-
oh-my-claude `post-merge` hook.

## Testing

The harness includes both a post-install verifier and dedicated test scripts:

```bash
bash verify.sh                              # Installation integrity check
bash tests/test-intent-classification.sh    # Intent routing logic
bash tests/test-quality-gates.sh            # Stop guard enforcement
bash tests/test-stall-detection.sh          # Loop detection
bash tests/test-e2e-hook-sequence.sh        # End-to-end hook sequence
bash tests/test-settings-merge.sh           # Install settings merge logic
bash tests/test-uninstall-merge.sh          # Uninstall settings cleanup logic
bash tests/test-common-utilities.sh         # Shared utility functions
bash tests/test-session-resume.sh           # Session resume cycle
bash tests/test-concurrency.sh              # Lock primitive stress test
bash tests/test-install-artifacts.sh        # Installed-file artifact assertions
bash tests/test-post-merge-hook.sh          # --git-hooks post-merge drift detection
bash tests/test-repro-redaction.sh          # omc-repro.sh privacy contract regression
bash tests/test-discovered-scope.sh         # Discovered-scope capture + wave-aware gate
bash tests/test-finding-list.sh             # Council Phase 8 findings.json artifact
bash tests/test-state-io.sh                 # Extracted lib/state-io.sh module
bash tests/test-classifier-replay.sh        # Classifier regression replay against curated fixtures
bash tests/test-serendipity-log.sh          # Serendipity Rule analytics logging
python3 -m unittest tests.test_statusline   # Statusline widget
```

## Customization

The harness is designed to be extended. Agent definitions, quality gate thresholds, domain routing rules, and specialist chains can all be modified to match your workflow.

- [Architecture](docs/architecture.md) -- system design and component interaction
- [Customization](docs/customization.md) -- what's configurable and how to change it safely
- [FAQ](docs/faq.md) -- common questions and troubleshooting
- [Prompts](docs/prompts.md) -- prompt reference and routing details

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on submitting changes, the review process, and how to test modifications to the harness locally.

## License

[MIT](LICENSE)
