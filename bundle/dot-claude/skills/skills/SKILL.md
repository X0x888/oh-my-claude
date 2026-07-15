---
name: skills
description: List all available oh-my-claude skills with descriptions and when to use each one.
---
# Available Skills

Display this list to the user, grouped by user-journey phase. Phase headers are themselves chapter markers — first-time users skim by phase, experienced users grep by skill name.

## Symptom → Skill quick-table

When you know what you want, jump straight to the verb:

| If you... | Use |
|---|---|
| Want to ship real work end-to-end | `/ulw <task>` |
| Keep working toward one durable goal across many turns | `/goal <objective>` |
| Just installed; want to feel the gates fire | `/ulw-demo` |
| Need to inspect or change configuration | `/omc-config` |
| Harness feels off / gates stopped firing | `/omc-doctor` |
| Need a plan before you edit | `/plan-hard <task>` |
| Need to review existing code | `/review-hard [focus]` |
| Wonder whether tests still earn their cost | `/test-audit [scope] [--apply]` |
| Need repo / API context before coding | `/research-hard <topic>` |
| Have a vague goal — need clarification | `/prometheus <goal>` |
| Have a draft plan — want it stress-tested | `/metis <plan>` |
| Stuck debugging — need a second opinion | `/oracle <issue>` |
| Multiple framings exist — pick consciously | `/diverge <task>` |
| Need official docs or external API | `/librarian <topic>` |
| Analyze experimental data / fit with uncertainties | `/data-analysis <task>` |
| Need verified academic sources / a bibliography | `/lit-review <topic>` |
| Writing or revising a paper, thesis, or referee response | `/manuscript <task>` |
| Want an adaptive multi-specialist project evaluation | `/council [focus]` |
| Want a design-first frontend pass | `/frontend-design <task>` |
| A gate fired but the work is complete | `/ulw-skip <reason>` |
| Discovered-scope flagged real items you defer | `/mark-deferred <reason>` |
| Blocked on a real operational input (credentials, login, dead infra) | `/ulw-pause <reason>` |
| Rate-limit kill left a resume artifact | `/ulw-resume` |
| Want session state / counters / flags | `/ulw-status` |
| Want a time-distribution card | `/ulw-time` |
| Want cross-session activity digest | `/ulw-report` |
| Want changelog deltas since your install | `/whats-new` |
| Want to bootstrap CLAUDE.md for a repo | `/atlas` |
| Memory directory feels noisy | `/memory-audit` |
| Want to deactivate ULW mid-session | `/ulw-off` |

The symptom-table above is a discovery shortcut. Each row maps to a skill in the phase-grouped tables below — those tables carry the full descriptions.

### Onboarding — first install, first task

| Skill | Command | When to use |
|-------|---------|-------------|
| **omc-config** | `/omc-config [setup\|update\|change]` | Guided multi-choice walkthrough for `oh-my-claude.conf` — pick a profile (Maximum / Balanced / Minimal) or fine-tune individual clusters. Auto-detects first-time setup vs upgrade vs ad-hoc change. |
| **omc-doctor** | `/omc-doctor` | One-shot install health check against the installed `~/.claude` tree (core files, @-includes, hook wiring, state root) — from any directory, days after install. Use when the harness feels off or gates stopped firing. |
| **ulw-demo** | `/ulw-demo` | Guided 90-second walkthrough that fires the quality gates on a demo file — best first step after install. |

### Working — your real tasks

| Skill | Command | When to use |
|-------|---------|-------------|
| **ulw** | `/ulw <task>` | Any non-trivial task needing full autonomy — coding, writing, research, ops. |
| **goal** | `/goal <objective>` | Drive a durable objective relentlessly across turns — re-anchored at every Stop until verifiably achieved or a no-progress stuck-wall (Codex `/goal` port). Lifecycle: pause/resume/clear/done. |
| **plan-hard** | `/plan-hard <task>` | You need a detailed plan *before* editing — scope decisions, architecture, sequencing. |
| **review-hard** | `/review-hard [focus]` | Review existing code or a worktree diff for bugs, quality, missed requirements. |
| **research-hard** | `/research-hard <topic>` | Gather repo context, API details, integration points before implementation. |
| **frontend-design** | `/frontend-design <task>` | Distinctive, design-first frontend work — establishes palette + typography + layout before code. |
| **data-analysis** | `/data-analysis <task>` | Scientific data analysis — explore, fit with honest uncertainties, publication-quality figures with provenance manifests. Peer-review standard, not just "the script ran". |
| **lit-review** | `/lit-review <topic>` | Verified academic literature review — every source registry-verified (Crossref/OpenAlex/S2/arXiv); never cites from memory. |
| **manuscript** | `/manuscript <task>` | Academic papers, theses, and referee responses — structure → verified citations → draft → rigor critique, in that order. |

### Stuck — second opinions, validations, escape hatches

| Skill | Command | When to use |
|-------|---------|-------------|
| **prometheus** | `/prometheus <goal>` | Goal is broad or ambiguous — needs interview-first clarification before planning. |
| **metis** | `/metis <plan>` | You have a draft plan and want to stress-test it for hidden risks, missing constraints. |
| **oracle** | `/oracle <issue>` | Debugging is hard, root cause unclear, or you need a second opinion on tradeoffs. |
| **diverge** | `/diverge <task>` | Multiple credible framings exist — generate 3-5 alternatives BEFORE commit to pick one consciously. Upstream of all the convergent critics. (v1.31.0) |
| **librarian** | `/librarian <topic>` | You need official docs, third-party API references, or concrete external examples. |
| **ulw-skip** | `/ulw-skip <reason>` | Gate fired but the work is genuinely complete (false positive). One-shot bypass. |
| **ulw-correct** | `/ulw-correct <correction>` | Last turn's classification was wrong — record misfire and (when parseable) update intent/domain in-place. Active counterpart to the passive `detect_classifier_misfire`. (v1.40.x) |
| **mark-deferred** | `/mark-deferred <reason>` | Discovered-scope flagged real findings you're consciously NOT shipping this session. |
| **ulw-pause** | `/ulw-pause <reason>` | Operational block only — credentials/login, hard external blocker, destructive shared-state action, unfamiliar in-progress state. NOT for taste/policy/credible-approach (v1.40.0: agent owns those under ULW). Cap 2/session. |
| **ulw-resume** | `/ulw-resume [--peek\|--list\|--dismiss]` | Atomically claim a `resume_request.json` after a rate-limit StopFailure. |

### Reviewing — multi-role evaluation, repo bootstrap

| Skill | Command | When to use |
|-------|---------|-------------|
| **council** | `/council [focus] [--deep]` | Coverage-map-driven evaluation from the full roster: normally 1–4 primary specialists, optional 0–2 gap-fill, and independent competence-matched verification of up to three findings. `--deep` escalates selected Sonnet-backed agents only. |
| **test-audit** | `/test-audit [scope] [--apply]` | Map behavior contracts to test owners and decide `KEEP`, `EXTEND`, `MERGE`, `REPLACE`, `DELETE`, or `ADD` by unique confidence, runtime, stability, and maintenance cost. Read-only unless `--apply` is passed. |
| **atlas** | `/atlas [focus]` | Bootstrap or refresh CLAUDE.md / `.claude/rules` for a repository. |

### Configuring & inspecting

| Skill | Command | When to use |
|-------|---------|-------------|
| **ulw-status** | `/ulw-status` | Inspect current session state — mode, domain, counters, flags (debugging). |
| **ulw-time** | `/ulw-time [current\|last\|last-prompt\|week\|month\|all]` | Polished time-distribution card — stacked top bar (`█` agents · `▒` tools · `░` idle), per-bucket chart, one-line insight. |
| **ulw-report** | `/ulw-report [last\|week\|month\|all]` | Markdown digest of cross-session activity — gate fires, reviewers, misfires, Serendipity catches. |
| **memory-audit** | `/memory-audit [--memory-dir <path>]` | Classify MEMORY.md entries (load-bearing, archival, superseded, drifted). Read-only. |
| **ulw-off** | `/ulw-off` | Deactivate ultrawork mode mid-session without ending the conversation. |
| **skills** | `/skills` | Show this list. |

### Model-invoked (no slash command)

These two skills auto-fire when Claude detects the matching work — there is no slash command to invoke them. They are listed here for discoverability; you never call them directly.

| Skill | Fires on | What it does |
|-------|----------|--------------|
| **swiftui-pro** | SwiftUI code in view | Reviews Swift/SwiftUI for modern-API usage, accessibility, data flow, navigation, performance, and Swift idioms. Partial-loads topic-scoped references. |
| **gamedev** | Unity / Godot / web-engine game work | Engine-idiomatic review + the frame-grounded run→capture→evaluate→fix loop for Unity (C#), Godot (GDScript/C#), and web engines (Phaser / Babylon / PixiJS / Three.js). |

## Decision guide

- **Just installed?** Run `/omc-config` for the guided multi-choice configuration walkthrough, then `/ulw-demo` to see the quality gates in action.
- **Already installed and want to inspect or change settings?** Use `/omc-config` (auto-detects mode).
- **Starting real work?** Use `/ulw` (aliases: `/autowork`, `/ultrawork` also work).
- **Need a plan first?** Use `/plan-hard`. If the goal is vague, use `/prometheus` instead.
- **Want to validate a plan?** Use `/metis`.
- **Want a multi-role project evaluation?** Use `/council`. It selects only the coverage the task needs; it also auto-triggers under `/ulw` for broad prompts like "evaluate my project," not a focused feature or subsystem audit.
- **Stuck debugging?** Use `/oracle`.
- **Need docs or references?** Use `/librarian`.
- **Want a code review?** Use `/review-hard`.
- **Wonder whether a test suite is stale, redundant, or too slow?** Use `/test-audit`; add `--apply` only when you want evidence-backed portfolio changes implemented.
- **Need repo context before building?** Use `/research-hard`.
- **Gate blocking but you're confident?** Use `/ulw-skip <reason>` to pass once.
- **Discovered-scope gate flagging findings you've consciously deferred?** Use `/mark-deferred <reason>` to bulk-defer all pending advisory findings with a recorded reason — keeps `/ulw-report` audits accurate.
- **Blocked on an OPERATIONAL input only the user can supply?** Use `/ulw-pause <reason>` — credentials/login, external account, hard external blocker, destructive shared-state action awaiting confirmation, unfamiliar in-progress state. Under v1.40.0 `no_defer_mode=on` (default), taste/policy/credible-approach are NOT pause cases — the agent picks the sane default and ships. Distinct from `/ulw-skip` (one-shot gate bypass) and `/mark-deferred` (legacy soft-defer, disabled under ULW execution).

### Deferral-verb decision tree

Three skills, three different "I can't keep going" cases — NOT interchangeable. The full decision tree (symptoms, when-NOT-to-use, validator-acceptable WHY shapes, v1.40.0 no-defer contract) is the canonical single source of truth in `~/.claude/quality-pack/memory/skills.md` → "Deferral-verb decision tree (which one to use)". That file loads into every session, so the model already has it; this page intentionally does not duplicate it.

Quick reference (symptom → verb):

| Symptom | Verb |
|---|---|
| Gate fired but the work is genuinely done (false positive) | `/ulw-skip <reason>` |
| Discovered-scope flagged real findings you're consciously NOT shipping *(v1.40.0: refused under ULW execution with default `no_defer_mode=on` — agent ships inline instead)* | `/mark-deferred <named-WHY>` |
| Blocked on an OPERATIONAL input — credentials/login, hard external blocker, destructive shared-state action, unfamiliar in-progress state | `/ulw-pause <reason>` |

Escalation order before any of these fires: **ship inline** → **wave-append** → **reject-as-not-a-defect** → **pause-for-operational-block**. Under ULW with `no_defer_mode=on` (default), `/mark-deferred` is unavailable; the agent owns technical judgment and ships.
- **Prior /ulw task killed by a Claude Code rate-limit window?** Use `/ulw-resume` — atomically claims the most relevant unclaimed `resume_request.json` for the current cwd (or matching project_key) and replays the original objective. The SessionStart resume-hint hook surfaces the artifact automatically; `/ulw-resume` is the explicit claim verb. Run `/ulw-resume --peek` to inspect first, `--list` to see all claimable artifacts.
- **MEMORY.md feels noisy or the drift hint fired?** Use `/memory-audit` — classifies entries and proposes rollup moves without moving anything itself.
- **Setting up a new repo?** Use `/atlas`.

> **Note:** Specialist agents activate automatically based on your task. You don't need to learn agent names — just describe what you want to accomplish.

> **See:** the "Auto-routed vs. manual escape hatches" subsection in `README.md` for the full tier breakdown — which specialists auto-suggest under `/ulw`, which fire from hooks, and which slash commands are escape hatches for standalone use.

> **What's with the names?** The mythology-themed skills (atlas, metis, oracle, prometheus, librarian) carry one-word mnemonics in `docs/glossary.md`. Search that page for the verb you want (plan, review, debug, look up docs) to find the matching skill.
