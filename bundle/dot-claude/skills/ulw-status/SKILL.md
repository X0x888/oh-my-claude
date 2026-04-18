---
name: ulw-status
description: Show the current ULW session state — workflow mode, domain, intent, counters, and flags. Use for debugging or inspecting what the hooks decided. Pass `summary` for a compact end-of-session recap.
---
# ULW Status

Parse any argument passed with the skill invocation (stored in `$ARGUMENTS`).
Treat the arguments case-insensitively.

- If the user passed `summary`, `-s`, or `--summary`, run the compact recap:

  ```
  bash ~/.claude/skills/autowork/scripts/show-status.sh --summary
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

If the session shows issues (guard exhausted, high stall counter, missing
verification, many classifier misfires), briefly note what it means.
