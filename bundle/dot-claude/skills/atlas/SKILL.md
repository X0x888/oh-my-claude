---
name: atlas
description: Bootstrap or refresh concise repo-specific instruction files for the current project so future Claude sessions follow the codebase's real conventions. Also handles deep-refresh audits of skill / agent definition files (`SKILL.md`, `agents/*.md`) when their bodies have drifted from the backing scripts and manual one-off patches no longer scale.
argument-hint: "[optional focus]"
disable-model-invocation: true
context: fork
agent: atlas
---
Inspect the current repository and create or refresh concise Claude instruction files.

For oh-my-claude-style repos with skill / agent definitions, Atlas can also do a **deep refresh** across all `bundle/dot-claude/skills/*/SKILL.md` and `bundle/dot-claude/agents/*.md` files — cross-referencing each one against its backing script for stale flag refs, renamed predicates, drifted counts, and cross-doc inventory inconsistencies. The agent's "SKILL.md / agent-definition refresh mode" instructions enumerate the exact drift categories.

Focus:

$ARGUMENTS
