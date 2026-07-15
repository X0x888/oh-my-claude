# Auto-Memory on Wrap-Up

For substantial execution, continuation, checkpoint, or compaction work, save only durable facts a future session cannot derive from source, docs, `git log`, or `CHANGELOG.md`. Advisory and session-management turns are memory-quiet unless the user explicitly asks to remember something.

Respect `auto_memory=off` (env > project > user); explicit “remember this” requests still win:

```bash
bash -c '. "${HOME}/.claude/skills/autowork/scripts/common.sh"; is_auto_memory_enabled' || echo "auto_memory=off — skip"
```

Write after quality gates pass and before Stop:

- `feedback_*.md` — confirmed/corrected collaboration preference and its reason.
- `user_*.md` — stable role, tooling, or workflow facts.
- `reference_*.md` — authoritative external systems/URLs future work must consult.
- `project_*.md` — non-obvious decision rationale, stakeholder/legal constraint, dated deferred risk, or post-mortem evidence.

Search `MEMORY.md` first. Update the existing subject; supersede wrong framing; never create duplicate files. Add one one-line index entry per memory file.

Reject release/shipped recaps, “what I did” summaries, commit/test/file counts, line-number inventories, code patterns, and architecture maps. If the fact is recoverable from the repository, do not save it. Never save secrets or credentials.

When `repo_lessons=on` (user/env only), a genuinely team-relevant non-derivable lesson may also be recorded with `record-repo-lesson.sh`; it becomes committable repository content, so apply the same bar and privacy rules.

Wrap-up and compaction are the two sweep moments. Running both is fine when the later pass updates rather than duplicates the earlier fact.
