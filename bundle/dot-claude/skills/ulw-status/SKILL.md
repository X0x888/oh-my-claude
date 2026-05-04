---
name: ulw-status
description: Show the current ULW session state — workflow mode, domain, intent, counters, and flags. Use for debugging or inspecting what the hooks decided. Pass `summary` for a compact end-of-session recap, `classifier` for intent-classifier telemetry, or `explain` for a per-flag rationale.
---
# ULW Status

Parse any argument passed with the skill invocation (stored in `$ARGUMENTS`).
Treat the arguments case-insensitively.

- If the user passed `summary`, `-s`, or `--summary`, run the compact recap:

  ```
  bash ~/.claude/skills/autowork/scripts/show-status.sh --summary
  ```

- If the user passed `classifier`, `-c`, or `--classifier`, run the
  intent-classifier telemetry surface:

  ```
  bash ~/.claude/skills/autowork/scripts/show-status.sh --classifier
  ```

- If the user passed `explain`, `-e`, or `--explain`, run the per-flag
  rationale (v1.30.0):

  ```
  bash ~/.claude/skills/autowork/scripts/show-status.sh --explain
  ```

- Otherwise, run the full diagnostic status:

  ```
  bash ~/.claude/skills/autowork/scripts/show-status.sh
  ```

Display the output as-is.

The `--summary` form is the right choice at end-of-session — it folds session
duration, edit counts, guard blocks, classifier misfires, reviewer verdicts,
and commits made during the session onto ~8 lines. It surfaces "invisible
friction" signals that the full dump buries, so the user can see patterns
(e.g. "3 sessions in a row with mostly-misfire PreTool blocks → tune the
classifier") that would otherwise live only in memory.

The `--explain` form (v1.30.0) walks the active `oh-my-claude.conf` and
prints each flag's current value, default, and one-line purpose, grouped
by category. Non-default values are flagged with a `*` marker. Use this
when you want to disable a flag (e.g., `intent_broadening`, `prompt_persist`)
but need to know what it does first — closes the "what does each flag
actually do?" gap that previously required reading the 422-line
`oh-my-claude.conf.example` file.

If the session shows issues (guard exhausted, high stall counter, missing
verification, many classifier misfires), briefly note what it means.
