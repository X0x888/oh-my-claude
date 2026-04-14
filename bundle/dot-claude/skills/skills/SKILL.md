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
| **atlas** | `/atlas [focus]` | Bootstrap or refresh CLAUDE.md / .claude/rules for a repository |
| **council** | `/council [focus]` | Multi-role project evaluation — dispatches PM, design, security, data, SRE, and growth perspectives |
| **ulw-demo** | `/ulw-demo` | Guided onboarding — see the quality gates fire on a demo task |
| **ulw-status** | `/ulw-status` | Inspect current session state — mode, domain, counters, flags (debugging) |
| **ulw-skip** | `/ulw-skip <reason>` | Skip the current quality gate block once — use when a gate is blocking but you're confident |
| **ulw-off** | `/ulw-off` | Deactivate ultrawork mode mid-session without ending the conversation |
| **skills** | `/skills` | Show this list |

## Decision guide

- **Just installed?** Use `/ulw-demo` to see the quality gates in action.
- **Starting real work?** Use `/ulw` (aliases: `/autowork`, `/ultrawork` also work).
- **Need a plan first?** Use `/plan-hard`. If the goal is vague, use `/prometheus` instead.
- **Want to validate a plan?** Use `/metis`.
- **Want a multi-role project evaluation?** Use `/council`. Also auto-triggers under `/ulw` for broad prompts like "evaluate my project."
- **Stuck debugging?** Use `/oracle`.
- **Need docs or references?** Use `/librarian`.
- **Want a code review?** Use `/review-hard`.
- **Need repo context before building?** Use `/research-hard`.
- **Gate blocking but you're confident?** Use `/ulw-skip <reason>` to pass once.
- **Setting up a new repo?** Use `/atlas`.

> **Note:** Specialist agents activate automatically based on your task. You don't need to learn agent names — just describe what you want to accomplish.
