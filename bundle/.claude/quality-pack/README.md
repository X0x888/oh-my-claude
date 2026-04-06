# Claude Code Quality Pack

This pack is a personal Claude Code workflow layer optimized for high-autonomy engineering work.

## What it installs

- User memory in `~/.claude/CLAUDE.md`
- Personal subagents in `~/.claude/agents/`
- Personal skills in `~/.claude/skills/`
- Skill-scoped hook scripts under `~/.claude/skills/autowork/scripts/`

## Main entry points

- `/autowork <task>`: maximum-autonomy execution flow
- `/ulw <task>`: short alias for the same maximum-autonomy flow
- `/ultrawork <task>`: long-form alias for the same flow
- `/sisyphus <task>`: compatibility alias for the same flow
- `/plan-hard <task>`: deep planning only
- `/review-hard [focus]`: findings-first review
- `/research-hard <topic>`: targeted codebase or API research
- `/prometheus <goal>`: interview-first planning
- `/metis <plan or focus>`: plan pressure-test and ambiguity check
- `/oracle <issue>`: debugging or architecture second opinion
- `/librarian <topic>`: official docs and reference implementation research
- `/atlas [focus]`: bootstrap or refresh repo-specific Claude instructions

## Design goals

- Plan first for non-trivial work
- Delegate aggressively to specialist subagents
- Review before finalizing
- Run meaningful verification after edits
- Keep aggressive behavior scoped to `/autowork` so the pack stays easy to remove
- Allow raw `ulw`, `ultrawork`, `autowork`, or `sisyphus` prompts to activate the same workflow semantics through a prompt hook
- Make the `ulw` family domain-aware so it can handle writing, research, operations, and mixed work rather than only coding tasks

## Rollback

This pack does not modify `~/.claude/settings.json`.

To remove it, delete:

- `~/.claude/CLAUDE.md`
- `~/.claude/quality-pack/`
- `~/.claude/agents/quality-planner.md`
- `~/.claude/agents/quality-reviewer.md`
- `~/.claude/agents/quality-researcher.md`
- `~/.claude/skills/autowork/`
- `~/.claude/skills/ulw/`
- `~/.claude/skills/plan-hard/`
- `~/.claude/skills/review-hard/`
- `~/.claude/skills/research-hard/`
