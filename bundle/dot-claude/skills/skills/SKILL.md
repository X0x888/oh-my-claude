---
name: skills
description: List all available oh-my-claude skills with descriptions and when to use each one.
---
# Available Skills

Display this list to the user, grouped by user-journey phase. Phase headers are themselves chapter markers — first-time users skim by phase, experienced users grep by skill name.

### Onboarding — first install, first task

| Skill | Command | When to use |
|-------|---------|-------------|
| **omc-config** | `/omc-config [setup\|update\|change]` | Guided multi-choice walkthrough for `oh-my-claude.conf` — pick a profile (Maximum / Balanced / Minimal) or fine-tune individual clusters. Auto-detects first-time setup vs upgrade vs ad-hoc change. |
| **ulw-demo** | `/ulw-demo` | Guided 90-second walkthrough that fires the quality gates on a demo file — best first step after install. |

### Working — your real tasks

| Skill | Command | When to use |
|-------|---------|-------------|
| **ulw** | `/ulw <task>` | Any non-trivial task needing full autonomy — coding, writing, research, ops. |
| **plan-hard** | `/plan-hard <task>` | You need a detailed plan *before* editing — scope decisions, architecture, sequencing. |
| **review-hard** | `/review-hard [focus]` | Review existing code or a worktree diff for bugs, quality, missed requirements. |
| **research-hard** | `/research-hard <topic>` | Gather repo context, API details, integration points before implementation. |
| **frontend-design** | `/frontend-design <task>` | Distinctive, design-first frontend work — establishes palette + typography + layout before code. |

### Stuck — second opinions, validations, escape hatches

| Skill | Command | When to use |
|-------|---------|-------------|
| **prometheus** | `/prometheus <goal>` | Goal is broad or ambiguous — needs interview-first clarification before planning. |
| **metis** | `/metis <plan>` | You have a draft plan and want to stress-test it for hidden risks, missing constraints. |
| **oracle** | `/oracle <issue>` | Debugging is hard, root cause unclear, or you need a second opinion on tradeoffs. |
| **diverge** | `/diverge <task>` | Multiple credible framings exist — generate 3-5 alternatives BEFORE commit to pick one consciously. Upstream of all the convergent critics. (v1.31.0) |
| **librarian** | `/librarian <topic>` | You need official docs, third-party API references, or concrete external examples. |
| **ulw-skip** | `/ulw-skip <reason>` | Gate fired but the work is genuinely complete (false positive). One-shot bypass. |
| **mark-deferred** | `/mark-deferred <reason>` | Discovered-scope flagged real findings you're consciously NOT shipping this session. |
| **ulw-pause** | `/ulw-pause <reason>` | User must make a decision only they can make (taste, policy, brand voice). Cap 2/session. |
| **ulw-resume** | `/ulw-resume [--peek\|--list\|--dismiss]` | Atomically claim a `resume_request.json` after a rate-limit StopFailure. |

### Reviewing — multi-role evaluation, repo bootstrap

| Skill | Command | When to use |
|-------|---------|-------------|
| **council** | `/council [focus] [--deep]` | Multi-role project evaluation — PM, design, security, data, SRE, growth lenses + verification pass. `--deep` escalates to opus. |
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

## Decision guide

- **Just installed?** Run `/omc-config` for the guided multi-choice configuration walkthrough, then `/ulw-demo` to see the quality gates in action.
- **Already installed and want to inspect or change settings?** Use `/omc-config` (auto-detects mode).
- **Starting real work?** Use `/ulw` (aliases: `/autowork`, `/ultrawork` also work).
- **Need a plan first?** Use `/plan-hard`. If the goal is vague, use `/prometheus` instead.
- **Want to validate a plan?** Use `/metis`.
- **Want a multi-role project evaluation?** Use `/council`. Also auto-triggers under `/ulw` for broad prompts like "evaluate my project."
- **Stuck debugging?** Use `/oracle`.
- **Need docs or references?** Use `/librarian`.
- **Want a code review?** Use `/review-hard`.
- **Need repo context before building?** Use `/research-hard`.
- **Gate blocking but you're confident?** Use `/ulw-skip <reason>` to pass once.
- **Discovered-scope gate flagging findings you've consciously deferred?** Use `/mark-deferred <reason>` to bulk-defer all pending advisory findings with a recorded reason — keeps `/ulw-report` audits accurate.
- **Need to pause for user input on a decision only the user can make?** Use `/ulw-pause <reason>` — declares a legitimate user-decision pause without tripping the session-handoff gate. Distinct from `/ulw-skip` (one-shot bypass) and `/mark-deferred` (defer findings).

### Deferral-verb decision tree (which one to use)

Three skills, three different "I can't keep going" cases. Pick by symptom — they are NOT interchangeable:

| Symptom | Skill |
|---|---|
| Gate fired but the work is done — false positive | `/ulw-skip <reason>` |
| Discovered-scope flagged real findings you're consciously NOT shipping | `/mark-deferred <named-WHY>` |
| User must make a call only they can make (taste, policy, brand voice) | `/ulw-pause <reason>` |

**Escalation order before any of these fires:** ship inline → wave-append → defer-with-WHY → pause. The `/mark-deferred` validator rejects (1) bare silent-skip patterns (`out of scope` / `follow-up` / `later` / `low priority`) AND (2) **effort excuses** (v1.35.0) — `requires significant effort` / `needs more time` / `blocked by complexity` / `tracks to a future session` / `superseded by future work` — that name the WORK COSTS instead of an EXTERNAL blocker. Pass with `requires <X>`, `blocked by <Y>`, `awaiting <Z>`, `superseded by <id>`, or single tokens/phrases like `duplicate` / `obsolete` / `wontfix` / `n/a` / `not reproducible` / `false positive`. The complementary `shortcut_ratio_gate` (v1.35.0) catches the **pattern** of half-or-more deferrals on big plans even when each individual reason has a valid WHY.
- **Prior /ulw task killed by a Claude Code rate-limit window?** Use `/ulw-resume` — atomically claims the most relevant unclaimed `resume_request.json` for the current cwd (or matching project_key) and replays the original objective. The SessionStart resume-hint hook surfaces the artifact automatically; `/ulw-resume` is the explicit claim verb. Run `/ulw-resume --peek` to inspect first, `--list` to see all claimable artifacts.
- **MEMORY.md feels noisy or the drift hint fired?** Use `/memory-audit` — classifies entries and proposes rollup moves without moving anything itself.
- **Setting up a new repo?** Use `/atlas`.

> **Note:** Specialist agents activate automatically based on your task. You don't need to learn agent names — just describe what you want to accomplish.

> **See:** the "Auto-routed vs. manual escape hatches" subsection in `README.md` for the full tier breakdown — which specialists auto-suggest under `/ulw`, which fire from hooks, and which slash commands are escape hatches for standalone use.

> **What's with the names?** The mythology-themed skills (atlas, metis, oracle, prometheus, librarian) carry one-word mnemonics in `docs/glossary.md`. Search that page for the verb you want (plan, review, debug, look up docs) to find the matching skill.
