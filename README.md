# oh-my-claude

**What if Claude Code couldn't cut corners?**

*Quality gates for Claude Code that actually block — until tests pass, review is done, and the work is verified.*

[![Version](https://img.shields.io/badge/Version-1.32.8-blue.svg)](CHANGELOG.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-bash-green.svg)]()
[![Dependencies](https://img.shields.io/badge/Dependencies-jq%20%2B%20rsync-brightgreen.svg)]()
[![Tests](https://img.shields.io/badge/Tests-2200%2B-brightgreen.svg)](tests/)

**Jump to:** [Install](#quick-start) · [AI-assisted install](#ai-assisted-install) · [What you get](#what-you-get) · [Feature highlights](#feature-highlights) · [Skills](#available-skills) · [Troubleshooting](#troubleshooting) · [FAQ](docs/faq.md)

A cognitive quality harness for Claude Code -- bash hooks, skills, and specialist agents that enforce thinking, testing, and review as structural requirements, not suggestions.

> **Type `/ulw <task>` to activate.** The harness classifies your prompt, routes the work to specialist agents (different chain per domain — coding, writing, research, ops), and runs quality gates that block until testing and review are done. You don't need to learn agent names.

![oh-my-claude /ulw-demo — quality gates in action](docs/ulw-demo.gif)

*Two minutes of `/ulw-demo` showing the quality gates fire on a real edit — see [Quick start](#quick-start) below to install and try it yourself.*

## What you get

- **Hard quality gates that actually block.** Claude can't mark a task done until tests, review, and verification are complete — no more "I've made the changes" with broken code or skipped review.
- **Domain routing across coding, writing, research, ops.** Each domain gets its own specialist chain. Not just a coding tool that accepts prose.
- **Session continuity through compaction.** Objectives, decisions, and review state survive context compaction — you don't lose the plot mid-task.

### What this is NOT

- **Not a plugin framework or SDK.** It's bash hooks + skills + agents installed as an overlay into `~/.claude/`.
- **Not a Claude Code replacement.** It sits *alongside* Claude Code; Claude Code's own surface is unchanged.
- **Not Anthropic-affiliated.** Community-built. Not the same project as `oh-my-claudecode` (separate Node-based tool).

---

## Quick start

Requires `jq` and `rsync`. macOS: `brew install jq` (`rsync` is preinstalled). Debian/Ubuntu: `apt install jq rsync`. `install.sh` hard-fails if `jq` is missing.

```bash
# One-liner (clones to ~/.local/share/oh-my-claude for you):
curl -fsSL https://raw.githubusercontent.com/X0x888/oh-my-claude/main/install-remote.sh | bash

# OR manual clone (audit before installing):
git clone https://github.com/X0x888/oh-my-claude.git ~/.local/share/oh-my-claude
bash ~/.local/share/oh-my-claude/install.sh
```

After install, two mandatory steps:

1. **Restart Claude Code.** Hooks load at session start — `/ulw` silently no-ops in your current session until you restart.
2. **Try it**: `/ulw-demo` (about 90 seconds, fires the gates on a real edit), then `/ulw <your task>` for real work in any domain.

That's enough to feel the harness work. When you want more:
- **Configure** with `/omc-config` *inside Claude Code* — the default install is the **Balanced** profile (low-friction defaults; sonnet model). For the strongest opinionated posture, run `/omc-config` and pick **Maximum Quality + Automation** (opus model, all bias-defense directives, watchdog on). Auto-detects first-time setup vs upgrade.
- **Verify on-disk install** with `bash ~/.local/share/oh-my-claude/verify.sh` from your terminal — useful when something feels off.

### When stuck — which deferral verb?

Three skills, three different "I can't keep going" cases. NOT interchangeable:

| Symptom | Verb |
|---|---|
| Gate fired but the work is genuinely complete (false positive) | `/ulw-skip <reason>` |
| Discovered-scope gate flagged real findings you've consciously deferred | `/mark-deferred <named-WHY>` |
| User must make a call only they can make (taste, policy, brand voice) | `/ulw-pause <reason>` |

Escalation order before any of these fires: ship inline → wave-append → defer-with-WHY → pause. Full decision tree in [`/skills`](#available-skills).

Both install paths keep Claude Code's permission prompts on; once you trust the harness, [`--bypass-permissions`](#power-user-setup) removes them. Quality gates apply either way.

Reversible: `bash ~/.local/share/oh-my-claude/uninstall.sh` removes everything cleanly (timestamped backups stay under `~/.claude/backups/`).

Already in Claude Code and want to skip the manual steps? See [AI-assisted install](#ai-assisted-install) below.

## AI-assisted install

Already in Claude Code? Paste one of these prompts directly. Each is self-contained, but the canonical step-by-step lives in the cloned repo's [`AGENTS.md` § "Agent Install Protocol"](AGENTS.md#agent-install-protocol--installing-or-updating-oh-my-claude) — the prompts point there so the README and the protocol don't drift.

**First-time install:**

> Install oh-my-claude. Do these in order:
> 1. Clone `https://github.com/X0x888/oh-my-claude.git` into `~/.local/share/oh-my-claude` (canonical path — matches the curl-pipe-bash bootstrapper).
> 2. Read `~/.local/share/oh-my-claude/AGENTS.md` § "Agent Install Protocol" and follow it end-to-end.
> 3. Use `--model-tier=balanced` (don't ask me).
> 4. After `verify.sh` passes, quote its "What next?" footer back to me verbatim — do not paraphrase.
> 5. Tell me explicitly to restart Claude Code and run `/ulw-demo` in the new session. Hooks won't fire in this current session.

**Update an existing install:**

> Update oh-my-claude. Read `repo_path=` from `~/.claude/oh-my-claude.conf`, then follow `<repo_path>/AGENTS.md` § "Agent Install Protocol" → Step 2 (Update). After running `install.sh` and `verify.sh`, list the commits the pull brought in and tell me whether to restart Claude Code (only if the bundle changed).

## Updating an existing install

```bash
cd ~/.local/share/oh-my-claude     # or your repo_path from ~/.claude/oh-my-claude.conf
git pull && bash install.sh
bash verify.sh
```

Restart Claude Code if any bundle file changed; the `verify.sh` summary lists orphans if files were removed.

Your `--model-tier` preference persists in `~/.claude/oh-my-claude.conf` and re-applies automatically. The statusline shows a yellow `↑v<version>` arrow when the source repo is ahead of the installed bundle — re-run `install.sh` to sync.

`install.sh` overwrites bundled files but preserves `settings.json` merges, `omc-user/overrides.md`, and custom agents or skills whose names are outside the bundle. See FAQ: [*How do I update?*](docs/faq.md#how-do-i-update-oh-my-claude) and [*Will updating overwrite my changes?*](docs/faq.md#will-updating-overwrite-my-changes) for the full safety matrix.

Reversible: `bash ~/.local/share/oh-my-claude/uninstall.sh` removes everything cleanly. Backups of pre-install settings live at `~/.claude/backups/oh-my-claude-<timestamp>/`.

## Troubleshooting

The first 60 seconds of common failure modes:

| Symptom | First check |
|---|---|
| `install.sh` exits with `jq: command not found` | Install `jq` first (`brew install jq` on macOS, `apt install jq` on Debian/Ubuntu) and re-run `install.sh`. |
| `verify.sh` reports errors | Re-run `bash install.sh`, then `verify.sh` again. Most failures are stale install or missing `jq`/`rsync`. |
| `/ulw` does nothing in your current session | You skipped the **restart Claude Code** step. Already-running sessions keep the previous hook wiring — open a new session. |
| `/ulw-demo` doesn't block at Step 3 | Install is stale (re-run `bash install.sh`) or `/ulw-off` was called earlier in the session. |
| Hooks fire but no behavior changes | Same root cause as the "current session" row above — restart needed. |
| Yellow `↑v<version>` arrow in the statusline | Source repo is ahead of the installed bundle. Run `git pull && bash install.sh` from the source repo to sync. |

For deeper issues, see [FAQ](docs/faq.md) — anomaly logs, config recovery, and per-gate disabling are documented there.

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

**Claude can't mark a task done until verification + review are complete.** Skip tests, skip the reviewer, defer work to a "future session" without a checkpoint, or edit 3+ files without an excellence review — each is a hard stop, not a warning. Caps on each gate prevent infinite loops: if Claude can't satisfy them, it surfaces the gap instead of spinning.

### Prescribed reviewer sequence

**On complex tasks (3+ edited files), the stop-hook prescribes the next reviewer instead of guessing.** Each reviewer owns one distinct dimension:

- `quality-reviewer` — bug hunt, code quality
- `design-reviewer` — design quality (auto-activates when UI files edited)
- `metis` — stress-test hidden assumptions
- `excellence-reviewer` — completeness against the original objective
- `editor-critic` — doc clarity and accuracy
- `briefing-analyst` — traceability (kicks in at 6+ files)

Each gate block message names the specific next reviewer. A `VERDICT: CLEAN|SHIP|FINDINGS (N)` line in each reviewer's output tells the hook whether the dimension was ticked. Doc-only edits route straight to `editor-critic` and skip the code-verification gate, so fixing a typo in CHANGELOG doesn't re-trigger `npm test`.

### Intent classification

**Every prompt is classified by intent and domain before Claude acts on it.** Five intent categories (execution, continuation, advisory, checkpoint, session-management) crossed with six domains (coding, writing, research, operations, mixed, general). Advisory questions get answered directly; execution prompts get the full specialist pipeline.

The classifier recognizes natural-English imperative shapes — including tail-position imperatives (`Review the plan. Then commit the changes.`) and implementation-verb-led conjunctions (`Implement and then commit as needed`). When the classifier mis-routes despite the widened patterns, a **prompt-text trust override** in the PreTool guard re-reads the most recent user prompt and allows destructive ops when the prompt itself authorizes them — even if the classifier disagreed. Compound-command safety: every destructive segment in `git commit && git push --force` must be authorized in the prompt text, not just the first one.

Five **bias-defense directive layers** can fire on `/ulw` prompts across three orthogonal axes (narrowing, widening, paradigm-enumeration; conf-gated):
- `prometheus_suggest` (off) — declare-and-proceed: when an execution prompt is short, product-shaped, and unanchored, tells the model to state its scope interpretation in one or two declarative sentences as part of its opener and proceed (no confirmation hold; user can redirect in real time).
- `intent_verify_directive` (off) — declare-and-proceed: when an execution prompt is short and unanchored, tells the model to state its goal interpretation in one declarative sentence as part of its opener and start work (no confirmation hold; user can redirect in real time).
- `exemplifying_directive` (on, v1.23.0) — when the prompt uses example markers (`for instance`, `e.g.`, `such as`, `as needed`, `similar to`, etc.), treat the example as ONE item from a class and enumerate sibling items rather than dropping the class. Defends against under-interpretation — implementing only the literal example when the prompt phrased it as an example is the failure mode `/ulw` was created to prevent.
- `intent_broadening` (on, v1.28.0) — defends against the "language is a limitation" failure mode. A complex /ulw prompt names some surfaces but rarely all of them. The directive injects a project-surface inventory reference (generated by `blindspot-inventory.sh`) and tells the model to surface gaps in its opener under a `**Project surfaces touched:**` line — ship the gap or defer with a one-line WHY, never silently miss a surface (release steps, env vars, tests, docs) the prompt didn't name.
- `divergence_directive` (on, v1.32.0) — defends against the "first paradigm wins" failure mode. When a prompt names a paradigm-shape decision (X-vs-Y choice, "how should we handle…", "what's the best way to model…", "design the X strategy", "is there a better way"), the directive instructs the model to enumerate 2-3 alternative framings INLINE in its opener — label + mental model + EASY/HARD affordance — then pick one with a one-line reason plus a "redirect if" clause naming the condition under which a different framing would win. Auto-fires on advisory + execution + continuation intents (paradigm enumeration is the right response to "what's the best way to model auth?", not just to imperative commands). Explicit `/diverge` remains the heavier escalation when inline enumeration feels shallow.

The widening layers have hard backstops: `exemplifying_scope_gate` (on) requires a state-backed checklist for example-marker prompts. Claude records sibling class items with `record-scope-checklist.sh`, then Stop is blocked until each item is marked shipped or declined with a concrete WHY. The blindspot inventory itself is conf-gated by `blindspot_inventory` (on); kill switch for shared machines or very large monorepos.

Reviewer findings (v1.28.0) are now machine-readable: each reviewer agent emits a single-line `FINDINGS_JSON: [{severity, category, file, line, claim, evidence, recommended_fix}, ...]` block before its verdict. Downstream gates parse the JSON preferentially over prose extraction; backward-compatible since prose fallback still works. The `check-latency-budgets.sh` script benchmarks the six hot-path hooks against per-hook ms budgets so speed regressions are caught before merge.

### Multi-domain routing

**Each domain has its own specialist chain — not a coding tool that happens to accept prose.**

- **Coding** -- quality-planner for scoping, quality-researcher for context, specialist developers (frontend, backend, fullstack, iOS, DevOps, test), quality-reviewer and excellence-reviewer for verification
- **Writing** -- writing-architect for structure, draft-writer for content, editor-critic for polish
- **Research** -- librarian for source gathering, briefing-analyst for synthesis, metis for stress-testing conclusions
- **Operations** -- chief-of-staff turns vague asks into structured deliverables, action plans, and decision memos

### Session continuity

**Objectives, decisions, and review state survive context compaction — you don't lose the plot mid-task.** Pre- and post-compact hooks snapshot the working state. Domain classification, accepted decisions, specialist conclusions, in-flight dispatches, and pending review obligations all carry over. When the session resumes, context is rehydrated — not reconstructed from scratch.

### Permissioned agents

**32 specialist agents — none can edit files; the main thread owns all mutations.** Each agent's `disallowedTools` is enforced at dispatch. Agents read, search, analyze, and plan; the main thread executes any changes they recommend. This keeps the main thread as the single source of truth and prevents unsupervised writes from agents operating on incomplete context.

### Project Council

**Solo developers get the cross-functional perspective of a full product team — without the team.** The `/council` skill dispatches a multi-role evaluation panel: Product Manager, UX Designer, Security Engineer, Data/Analytics Lead, SRE, Growth Lead. Each role-lens agent evaluates independently with a non-overlapping mandate, and findings are synthesized into a single prioritized assessment. The system auto-detects broad evaluation prompts like "evaluate my project" under `/ulw` and triggers the council flow automatically.

### Distinctive UI by default

**Ask for a landing page or any UI work and you get a 9-section Design Contract — palette with hex values, typography rules, component states, layout, depth, do's & don'ts — before any code is written.** Concrete commitments instead of generic shadcn-default aesthetics. Scope-aware: a "build a page" prompt gets the full contract; a "fix the button padding" prompt preserves existing tokens. Skip with `no design polish` for backend/internal work.

15 brand archetypes (Linear, Stripe, Vercel, Notion, Apple, Airbnb, Spotify, Tesla, Figma, Discord, Raycast, Anthropic, Webflow, Mintlify, Supabase) are framed as *anti-anchors* — the agent picks a coherent starting point and commits to what it will do *differently*. Cross-session archetype memory prevents the same anchor from being picked twice on the same project. Inline contract emission lets `design-reviewer` and `visual-craft-lens` grade drift even when no `DESIGN.md` exists at the project root. Inspired by [VoltAgent/awesome-design-md](https://github.com/VoltAgent/awesome-design-md).

### Zero dependencies

**No npm. No TypeScript. No Node.js runtime. No plugin framework.** The entire harness is bash scripts and `jq`. It works anywhere Claude Code runs, installs in seconds, and leaves no footprint beyond the `~/.claude/` directory.

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

How oh-my-claude differs from vanilla Claude Code:

| | Vanilla Claude Code | oh-my-claude |
|---|---|---|
| **Quality enforcement** | None | Hard stop gates |
| **Intent classification** | None | 5-category state machine |
| **Domain coverage** | Code-focused | Coding, writing, research, ops |
| **Dependencies** | -- | bash + jq |
| **Agent safety** | Unrestricted | `disallowedTools` enforced |
| **Session continuity** | Lost on compaction | Pre/post-compact hooks |
| **Architecture** | Monolithic | Harness hooks |

> Sometimes confused with `oh-my-claudecode`, which is a separate Node.js/TypeScript plugin framework for Claude Code. See [FAQ](docs/faq.md#how-is-this-different-from-oh-my-claudecode) for the structural differences.

---

## Repository structure

```
oh-my-claude/
├── install.sh / uninstall.sh / verify.sh   # Install, remove, and verify
├── bundle/dot-claude/                       # Installs to ~/.claude/
│   ├── agents/          (34 agents)         # Specialist agent definitions
│   ├── skills/          (24 skills)         # Skill definitions + autowork hooks
│   ├── quality-pack/                        # Lifecycle hooks + memory files
│   ├── output-styles/                       # Two bundled styles: oh-my-claude (default) + executive-brief (see docs/customization.md#output-style)
│   └── statusline.py                        # Custom statusline widget
├── config/settings.patch.json               # Merged into user settings on install
├── tests/               (63 bash + 1 py)    # See AGENTS.md / CONTRIBUTING.md for full list
├── tools/                                    # Developer-only tools (not installed)
└── docs/                                    # Architecture, customization, FAQ, prompts
```

For repo-internal architecture and contribution conventions, see [AGENTS.md](AGENTS.md) (architecture, state I/O, agent VERDICT contract) and [CONTRIBUTING.md](CONTRIBUTING.md) (testing, release process).

> **Why `dot-claude` instead of `.claude`?** Claude Code's permission system treats paths containing `.claude/` as sensitive, triggering prompts on every edit during development. The installer copies `bundle/dot-claude/` into `~/.claude/` on your machine. Same pattern as oh-my-zsh, chezmoi, etc.

### Available skills

Skills are invoked as slash commands or routed automatically by the intent classifier.

| Skill (mnemonic) | Command | Purpose |
|---|---|---|
| **Run a task** | | |
| ulw | `/ulw <task>` | Maximum-autonomy professional workflow |
| **Think before acting** | | |
| plan-hard *(plan)* | `/plan-hard <task>` | Decision-complete planning without edits |
| prometheus *(interview)* | `/prometheus <goal>` | Interview-first planning for ambiguous work |
| metis *(stress-test)* | `/metis <plan>` | Pressure-test a plan for hidden risks |
| oracle *(second opinion)* | `/oracle <issue>` | Deep debugging or architecture second opinion |
| diverge *(expand option space)* | `/diverge <task>` | Generate 3-5 alternative framings BEFORE commit (v1.31.0; upstream of convergent critics). v1.32.0: also auto-suggested under `/ulw` on paradigm-shape prompts via the `divergence_directive` (X-vs-Y, "how should we", "best way to model X", etc.) — inline 2-3 framings is the default; explicit `/diverge` is the escalation. |
| librarian *(docs lookup)* | `/librarian <topic>` | Official docs and reference research |
| **Review & evaluate** | | |
| review-hard *(review)* | `/review-hard [focus]` | Findings-first code review |
| research-hard *(research)* | `/research-hard <topic>` | Targeted context gathering |
| council *(evaluation panel)* | `/council [focus] [--deep]` | Multi-role project evaluation with top-finding verification, then **Phase 8** wave-by-wave execution when fixes are requested. Recognizes natural authorization vocabulary ("do all", "make X impeccable", "0 or 1", "fix everything", "implement all", etc. — full canonical list in `bundle/dot-claude/skills/council/SKILL.md` Step 8). `--deep` escalates lenses to opus. |
| **Build** | | |
| frontend-design *(visual craft)* | `/frontend-design <task>` | Distinctive design-first frontend work |
| atlas *(repo bootstrap)* | `/atlas [focus]` | Bootstrap or refresh repo instruction files |
| **Configure** | | |
| omc-config *(setup walkthrough)* | `/omc-config [setup\|update\|change]` | Multi-choice walkthrough for `oh-my-claude.conf` flags. Auto-detects first-time setup vs upgrade vs ad-hoc change. Picks a profile (Maximum Quality + Automation / Balanced / Minimal) or fine-tunes individual flags — no typing required. Triggered by phrases like "help me install", "configure oh-my-claude", "update my settings". |
| **Workflow control** (mid-session) | | |
| ulw-demo *(onboarding)* | `/ulw-demo` | Guided walkthrough with real quality gates |
| ulw-status *(diagnostics)* | `/ulw-status` | Show current session state and Council Phase 8 wave-plan progress. `summary` / `classifier` arguments swap modes. |
| ulw-time *(time distribution)* | `/ulw-time [current\|last\|last-prompt\|week\|month\|all]` | Polished end-of-turn time card — stacked top bar (`█` agents · `▒` tools · `░` idle), per-bucket ASCII chart, and a one-line insight (anomaly / dominance / reassurance / fun fact). The same card auto-emits as Stop `systemMessage` above the 5s noise floor; manual invocations slice a different window or bypass the floor. |
| ulw-report *(retrospective)* | `/ulw-report [last\|week\|month\|all]` | Markdown digest of cross-session activity — sessions, gate fires, top reviewers, classifier misfires, Serendipity catches, finding/wave outcomes |
| memory-audit *(memory hygiene)* | `/memory-audit [--memory-dir <path>]` | Classify MEMORY.md entries (load-bearing, archival, superseded, drifted) and propose rollup moves. Read-only. |
| ulw-skip *(skip a gate)* | `/ulw-skip <reason>` | Skip current quality gate block once |
| mark-deferred *(triage findings)* | `/mark-deferred <reason>` | Bulk-defer pending discovered-scope findings with a one-line reason — pass the gate without silent skipping |
| ulw-pause *(user-decision pause)* | `/ulw-pause <reason>` | Declare a legitimate user-decision pause without tripping the session-handoff gate. Cap 2/session |
| ulw-resume *(post-rate-limit recovery)* | `/ulw-resume [--peek \| --list \| --session-id <sid> \| --dismiss]` | Atomically claim and replay the most relevant unclaimed `resume_request.json` — picks up a /ulw task that a Claude Code rate-limit kill interrupted. `--dismiss` suppresses the SessionStart hint without resuming. Pairs with the SessionStart resume-hint hook (Wave 1) and the headless watchdog (Wave 3). |
| ulw-off *(deactivate)* | `/ulw-off` | Deactivate ultrawork mode mid-session |
| skills *(this list)* | `/skills` | List all available skills with usage guide |

> The mythology-named skills (atlas, metis, oracle, prometheus, librarian) carry one-word mnemonics — see [`docs/glossary.md`](docs/glossary.md) for the rationale behind each name.
>
> `/ulw` is the canonical user-facing name. The legacy aliases `/autowork`, `/ultrawork`, and `sisyphus` remain wired in the classifier for muscle-memory continuity but new prompts and docs should lead with `/ulw`. (v1.31.0 — naming consolidation.)

### Auto-routed vs. manual escape hatches

**You don't have to learn the slash commands.** Here's what runs without you typing anything:

| Tier | Mechanism | What you get |
|---|---|---|
| **Hook-fired (mandatory)** | Fires automatically — you can't bypass it | `quality-reviewer` before stop, `excellence-reviewer` on complex tasks, `design-reviewer` when UI files are edited |
| **Router-suggested (reasoning)** under `/ulw` | Injected as a directive when prompt signals match | `prometheus`, `quality-planner`, `quality-researcher`, `librarian`, `metis`, `oracle` |
| **Router-suggested (engineering)** under `/ulw` | Same mechanism — extended to engineering specialists in this release | `backend-api-developer`, `devops-infrastructure-engineer`, `test-automation-engineer`, `fullstack-feature-builder`, `ios-ui-developer`, `ios-core-engineer`, `ios-deployment-specialist`, `ios-ecosystem-integrator`, `abstraction-critic` |
| **Auto-dispatched on prompt pattern** | An entire workflow (multi-agent + gates) fires when the router detects the pattern | `/council` for broad project-evaluation prompts, the 9-section Design Contract on UI work |
| **Manual control/diagnostic** *(by design)* | You declare intent — auto-firing would be wrong | `/ulw-skip`, `/ulw-pause`, `/mark-deferred`, `/ulw-status`, `/ulw-time`, `/ulw-report`, `/ulw-off`, `/skills` |
| **Manual setup/audit** | One-time or occasional | `/atlas`, `/memory-audit`, `/ulw-demo`, `/omc-config` |

Most quality-boosting specialists are auto-suggested by the prompt-intent-router under `/ulw` based on prompt signals — `/ulw fix the auth bug` automatically nudges toward `oracle` for hard debugging, `librarian` for unfamiliar APIs, `quality-reviewer` before stop, and so on. You don't have to type `/oracle` to get Oracle — the slash command is the standalone escape hatch, not the only path in.

## Power-user setup

Once you've run `/ulw-demo`, watched the quality gates fire, and decided you trust the harness, you can remove Claude Code's per-tool approval prompts:

```bash
bash install.sh --bypass-permissions
```

This is opt-in. It skips Claude Code's built-in "allow this tool?" prompts so `/ulw` runs without interruption. The harness's quality gates (verification, reviewer dispatch, stop-guard) keep working — those are independent of Claude Code's confirmation layer. Switch back at any time by re-running `bash install.sh` without the flag.

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
bash tests/test-exemplifying-scope-gate.sh  # Example-marker scope checklist + stop gate
bash tests/test-finding-list.sh             # Council Phase 8 findings.json artifact
bash tests/test-state-io.sh                 # Extracted lib/state-io.sh module
bash tests/test-classifier.sh               # Extracted lib/classifier.sh module (symbol presence + smoke)
bash tests/test-classifier-replay.sh        # Classifier regression replay against curated fixtures
bash tests/test-serendipity-log.sh          # Serendipity Rule analytics logging
bash tests/test-cross-session-rotation.sh   # Cross-session JSONL aggregate cap helper
bash tests/test-show-report.sh              # /ulw-report skill backend (cross-session digest)
bash tests/test-install-remote.sh           # curl-pipe-bash bootstrapper (install-remote.sh)
bash tests/test-phase8-integration.sh       # Council Phase 8 wave-cap wiring (record-finding-list ↔ stop-guard)
bash tests/test-verification-lib.sh         # Extracted lib/verification.sh module (symbol presence + smoke)
bash tests/test-agent-verdict-contract.sh   # Universal VERDICT contract regression net (all 34 agents)
bash tests/test-bias-defense-classifier.sh  # Bias-defense prompt-shape classifiers + plan-complexity extraction
bash tests/test-bias-defense-directives.sh  # prometheus-suggest + intent-verify directive injection
bash tests/test-metis-on-plan-gate.sh       # Metis-on-plan stop-guard gate (Check 6, opt-in)
bash tests/test-gate-events.sh              # Per-event outcome attribution (gate_events.jsonl helper + wiring)
bash tests/test-discover-session.sh         # Cross-project session-discovery cwd filter (record-finding-list / show-status)
bash tests/test-design-contract.sh          # 9-section Design Contract regression net (UI agents + skill + router)
bash tests/test-specialist-routing.sh       # Engineering-specialist routing in coding-domain hint (orphan-specialist regression net)
bash tests/test-stop-failure-handler.sh     # StopFailure hook captures rate_limit / auth / billing fatal-stop signals into resume_request.json
bash tests/test-omc-config.sh               # /omc-config skill backend (mode detection, atomic conf writes, presets, validation)
bash tests/test-output-style-coherence.sh   # All bundled styles: frontmatter parity, hook-injected opener coherence, label regression net, enum coverage
bash tests/test-timing.sh                   # Per-prompt time-distribution capture, aggregator, format helpers, /ulw-time empty-states
python3 -m unittest tests.test_statusline   # Statusline widget
```

## Customization

The harness is designed to be extended. Agent definitions, quality gate thresholds, domain routing rules, and specialist chains can all be modified to match your workflow.

- [Architecture](docs/architecture.md) -- system design and component interaction
- [Customization](docs/customization.md) -- what's configurable and how to change it safely
- [FAQ](docs/faq.md) -- common questions and troubleshooting
- [Prompts](docs/prompts.md) -- prompt reference and routing details
- [Glossary](docs/glossary.md) -- decoder ring for the mythology-named skills and internal terms
- [Showcase](docs/showcase.md) -- real-world transcripts where the gates caught a bug or stalled completion (community-contributed)

## Auto-resume after a Claude Code rate-limit kill

When Claude Code's 5-hour or 7-day rate-limit window expires mid-task, the session terminates with a `StopFailure`. By default the harness now captures the moment via three layers, so the work picks up "as if it were not interrupted" once the cap clears:

1. **Substrate (always on, privacy-aware)**. The `StopFailure` hook persists `~/.claude/quality-pack/state/<session>/resume_request.json` carrying the original objective, last user prompt, matcher, reset epoch, and project key. Set `stop_failure_capture=off` in `~/.claude/oh-my-claude.conf` to opt out of the capture (shared machines / regulated codebases).
2. **SessionStart hint (always on)**. The next time you open Claude Code in that project, a SessionStart hook surfaces the unclaimed artifact's objective and reset timing as `additionalContext`. Either invoke `/ulw-resume` to atomically claim and replay the original prompt, or `/ulw-resume --dismiss` to silence the hint without resuming.
3. **Headless watchdog (opt-in)**. A LaunchAgent (macOS), systemd user-timer (Linux), or cron entry runs every ~2 minutes. When a rate-limit window clears it atomically claims the artifact, then launches `claude --resume <session_id> '<original prompt>'` in a detached `tmux` session named `omc-resume-<sid>` rooted at the original cwd. Attach with `tmux attach -t omc-resume-<sid>`.

Activate the watchdog:

```bash
bash ~/.claude/install-resume-watchdog.sh
```

The installer detects your platform, registers the scheduler, sets `resume_watchdog=on`, and runs a dry-tick to confirm health. Tail the log at `~/.claude/quality-pack/state/.watchdog-logs/resume-watchdog.log` (macOS) or `journalctl --user -u oh-my-claude-resume-watchdog.service -f` (Linux).

When `tmux` is not available the watchdog falls back to an OS notification — you click the alert, open Claude Code, and run `/ulw-resume` manually. To uninstall the watchdog: `bash ~/.claude/install-resume-watchdog.sh --uninstall [--reset-conf]`.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on submitting changes, the review process, and how to test modifications to the harness locally.

## License

[MIT](LICENSE)
