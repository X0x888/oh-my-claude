---
name: skills
description: List all available oh-my-claude skills with descriptions and when to use each one.
---
# Available Skills

Display this table to the user:

| Skill | Command | When to use |
|-------|---------|-------------|
| **ulw** | `/ulw <task>` | Any non-trivial task needing full autonomy — coding, writing, research, ops |
| **plan-hard** | `/plan-hard <task>` | You need a detailed plan *before* editing — scope decisions, architecture, sequencing |
| **review-hard** | `/review-hard [focus]` | Review existing code or a worktree diff for bugs, quality, and missed requirements |
| **research-hard** | `/research-hard <topic>` | Gather repo context, API details, or integration points before implementation |
| **prometheus** | `/prometheus <goal>` | The goal is broad or ambiguous — needs interview-first clarification before planning |
| **metis** | `/metis <plan>` | You have a draft plan or approach and want to stress-test it for hidden risks |
| **oracle** | `/oracle <issue>` | Debugging is hard, root cause is unclear, or you need a second opinion on tradeoffs |
| **librarian** | `/librarian <topic>` | You need official docs, third-party API references, or concrete external examples |
| **frontend-design** | `/frontend-design <task>` | Distinctive, design-first frontend work — establishes palette, typography, layout before writing code |
| **atlas** | `/atlas [focus]` | Bootstrap or refresh CLAUDE.md / .claude/rules for a repository |
| **council** | `/council [focus] [--deep]` | Multi-role project evaluation — dispatches PM, design, security, data, SRE, and growth perspectives, then verifies the top 2-3 findings via `oracle`. `--deep` escalates lenses to opus for high-stakes audits. |
| **omc-config** | `/omc-config [setup\|update\|change]` | Guided multi-choice walkthrough for `oh-my-claude.conf` flags — pick a profile (Maximum Quality + Automation / Balanced / Minimal) or fine-tune individual flags. Auto-detects first-time setup vs upgrade vs ad-hoc change. |
| **ulw-demo** | `/ulw-demo` | Guided onboarding — see the quality gates fire on a demo task |
| **ulw-status** | `/ulw-status` | Inspect current session state — mode, domain, counters, flags (debugging) |
| **ulw-report** | `/ulw-report [last\|week\|month\|all]` | Markdown digest of cross-session activity — sessions, gate fires, reviewers, misfires, Serendipity catches, finding/wave outcomes |
| **memory-audit** | `/memory-audit [--memory-dir <path>]` | Classify MEMORY.md entries (load-bearing, archival, superseded, drifted) and propose rollup moves. Read-only — never moves or deletes files. |
| **ulw-skip** | `/ulw-skip <reason>` | Skip the current quality gate block once — use when a gate is blocking but you're confident |
| **mark-deferred** | `/mark-deferred <reason>` | Bulk-defer pending discovered-scope findings with a one-line reason — pass the gate without silent skipping |
| **ulw-pause** | `/ulw-pause <reason>` | Declare a legitimate user-decision pause without tripping the session-handoff gate (taste / policy / credible-approach split). Cap 2/session |
| **ulw-resume** | `/ulw-resume [--peek \| --list \| --session-id <sid>]` | Atomically claim and replay an unclaimed `resume_request.json` after a Claude Code rate-limit StopFailure — picks up the prior /ulw task as if it were never interrupted |
| **ulw-off** | `/ulw-off` | Deactivate ultrawork mode mid-session without ending the conversation |
| **skills** | `/skills` | Show this list |

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
- **Prior /ulw task killed by a Claude Code rate-limit window?** Use `/ulw-resume` — atomically claims the most relevant unclaimed `resume_request.json` for the current cwd (or matching project_key) and replays the original objective. The SessionStart resume-hint hook surfaces the artifact automatically; `/ulw-resume` is the explicit claim verb. Run `/ulw-resume --peek` to inspect first, `--list` to see all claimable artifacts.
- **MEMORY.md feels noisy or the drift hint fired?** Use `/memory-audit` — classifies entries and proposes rollup moves without moving anything itself.
- **Setting up a new repo?** Use `/atlas`.

> **Note:** Specialist agents activate automatically based on your task. You don't need to learn agent names — just describe what you want to accomplish.

> **See:** the "Auto-routed vs. manual escape hatches" subsection in `README.md` for the full tier breakdown — which specialists auto-suggest under `/ulw`, which fire from hooks, and which slash commands are escape hatches for standalone use.

> **What's with the names?** The mythology-themed skills (atlas, metis, oracle, prometheus, librarian) carry one-word mnemonics in `docs/glossary.md`. Search that page for the verb you want (plan, review, debug, look up docs) to find the matching skill.
