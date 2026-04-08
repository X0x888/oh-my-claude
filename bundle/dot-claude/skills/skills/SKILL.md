---
name: skills
description: List all available oh-my-claude skills with descriptions and when to use each one.
---
# Available Skills

Display this table to the user:

| Skill | Command | When to use |
|-------|---------|-------------|
| **autowork** | `/autowork <task>` | Any non-trivial task needing full autonomy — coding, writing, research, ops |
| **ulw** | `/ulw <task>` | Same as autowork (short alias) |
| **plan-hard** | `/plan-hard <task>` | You need a detailed plan *before* editing — scope decisions, architecture, sequencing |
| **review-hard** | `/review-hard [focus]` | Review existing code or a worktree diff for bugs, quality, and missed requirements |
| **research-hard** | `/research-hard <topic>` | Gather repo context, API details, or integration points before implementation |
| **prometheus** | `/prometheus <goal>` | The goal is broad or ambiguous — needs interview-first clarification before planning |
| **metis** | `/metis <plan>` | You have a draft plan or approach and want to stress-test it for hidden risks |
| **oracle** | `/oracle <issue>` | Debugging is hard, root cause is unclear, or you need a second opinion on tradeoffs |
| **librarian** | `/librarian <topic>` | You need official docs, third-party API references, or concrete external examples |
| **atlas** | `/atlas [focus]` | Bootstrap or refresh CLAUDE.md / .claude/rules for a repository |
| **ulw-status** | `/ulw-status` | Inspect current session state — mode, domain, counters, flags (debugging) |
| **ulw-off** | `/ulw-off` | Deactivate ultrawork mode mid-session without ending the conversation |
| **skills** | `/skills` | Show this list |

## Decision guide

- **Starting real work?** Use `/ulw` (or `/autowork`).
- **Need a plan first?** Use `/plan-hard`. If the goal is vague, use `/prometheus` instead.
- **Want to validate a plan?** Use `/metis`.
- **Stuck debugging?** Use `/oracle`.
- **Need docs or references?** Use `/librarian`.
- **Want a code review?** Use `/review-hard`.
- **Need repo context before building?** Use `/research-hard`.
- **Setting up a new repo?** Use `/atlas`.
