---
name: ulw-time
description: Show where this prompt's (or session's) wall time went — per-tool and per-subagent distribution rendered as an ASCII bar chart. Pass `last-prompt` to slice the most recently finalized prompt, `last` for the most recent session, `week` / `month` / `all` for cross-session rollups. Use to answer "why did that prompt take so long?" and "which agents are the most expensive in my workflow?".
---

# ULW Time

Parse any argument passed with the skill invocation (stored in `$ARGUMENTS`).
Treat the arguments case-insensitively.

- No argument (or `current`): full breakdown for the **active session** —
  walltime, agents (with per-subagent rows), tools (with per-tool rows
  and call counts), idle/model residual:

  ```
  bash ~/.claude/skills/autowork/scripts/show-time.sh
  ```

- `last-prompt`: slice the **most recently finalized prompt** out of the
  active session. Answers "where did THAT prompt go?" without aggregating
  prior prompts:

  ```
  bash ~/.claude/skills/autowork/scripts/show-time.sh last-prompt
  ```

- `last`: same shape as `current` but for the **most recent finalized
  session**:

  ```
  bash ~/.claude/skills/autowork/scripts/show-time.sh last
  ```

- `week` (default cross-session window) / `month` / `all`: rollup across
  every recorded session inside the window, top 10 agents and top 10
  tools by total time:

  ```
  bash ~/.claude/skills/autowork/scripts/show-time.sh week
  bash ~/.claude/skills/autowork/scripts/show-time.sh month
  bash ~/.claude/skills/autowork/scripts/show-time.sh all
  ```

Display the output as-is.

## Reading the breakdown

- **Walltime** is the sum of every prompt's UserPromptSubmit→Stop interval
  in the window.
- **Agents** is paired Agent-tool durations, attributed by `subagent_type`
  (so `quality-reviewer`, `excellence-reviewer`, etc. become individually
  visible). When an Agent call's duration is unknown — e.g., killed by a
  rate-limit mid-call — it falls into the orphan counter at the bottom.
- **Tools** is paired non-Agent tool durations (`Bash`, `Read`, `Edit`,
  MCP tools, etc.). Each row also shows `(N)` — the number of calls in
  the bucket. Sub-second tools (Read/Grep) often round to `0s` under
  whole-second precision; the call count makes that bucket visible
  even when its time contribution is rounded away.
- **Idle/model** is `walltime − (agents + tools)`. It includes model
  thinking time, user-permission-prompt waits, and hook overhead. A
  large idle/model bucket on a long prompt usually means the model
  spent significant time thinking, OR there was a long permission-prompt
  delay; tool spans don't account for it because no tool call was active.

## When the data is empty

If the active session has no recorded prompts yet (e.g., this is the first
turn after invoking ULW), the script prints an empty-state line. Run it
again after at least one tool call has completed.

If `time_tracking=off` in `~/.claude/oh-my-claude.conf` (or
`OMC_TIME_TRACKING=off` in the environment), capture is disabled and no
data is recorded. Re-enable in `oh-my-claude.conf` or via `/omc-config`.
