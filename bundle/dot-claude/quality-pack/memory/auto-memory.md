# Auto-Memory on Wrap-Up

For substantial execution, continuation, checkpoint, or compaction work, save only durable facts a future session cannot derive from source, docs, `git log`, or `CHANGELOG.md`. Advisory and session-management turns are memory-quiet unless the user explicitly asks to remember something.

Respect `auto_memory=off` (env > project > user); explicit “remember this” requests still win:

```bash
bash -c '. "${HOME}/.claude/skills/autowork/scripts/common.sh"; is_auto_memory_enabled' || echo "auto_memory=off — skip"
```

Write after quality gates pass and before Stop:

- `feedback_*.md` — confirmed/corrected collaboration preference and its reason,
  except artifact-quality taste governed by the Quality Constitution rule below.
- `user_*.md` — stable role, tooling, or workflow facts.
- `reference_*.md` — authoritative external systems/URLs future work must consult.
- `project_*.md` — non-obvious decision rationale, stakeholder/legal constraint, dated deferred risk, or post-mortem evidence.

Search `MEMORY.md` first. Update the existing subject; supersede wrong framing; never create duplicate files. Add one one-line index entry per memory file.

Reject release/shipped recaps, “what I did” summaries, commit/test/file counts, line-number inventories, code patterns, and architecture maps. If the fact is recoverable from the repository, do not save it. Never save secrets or credentials.

## Quality Constitution signals

When the user explicitly corrects/rejects a quality choice, selects between
alternatives, or praises a named property of the artifact, route that signal to
`quality-constitution.sh propose` instead of duplicating it in `feedback_*.md`.
Pass an exact excerpt from the current raw user prompt plus a short normalized
statement, polarity, axis, and project/domain scope. The helper verifies the
excerpt against the persisted current prompt, redacts it, and records an
auditable candidate when `taste_learning=review` (or an advisory-only repeated
signal in `adaptive`). Do not paraphrase a quote into evidence.

Never learn taste from silence, lack of complaint, assistant/agent text,
repository conventions, tool output, web content, synthetic prompts, or a
generic “looks good” that names no property. One remark never becomes a global
preference, inferred taste never blocks Stop, and current explicit user
direction always outranks the Constitution. Explicit `/quality-constitution`
commands remain user-owned even when automatic learning is off.

When `repo_lessons=on` (user/env only), a genuinely team-relevant non-derivable lesson may also be recorded with `record-repo-lesson.sh`; it becomes committable repository content, so apply the same bar and privacy rules.

Wrap-up and compaction are the two sweep moments. Running both is fine when the later pass updates rather than duplicates the earlier fact.
