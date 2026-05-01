---
name: ulw-time
description: Show where this prompt's (or session's) wall time went — polished end-of-turn card with a stacked-segment top bar (`█` agents · `▒` tools · `░` idle), per-bucket per-row chart, and a closing insight line. Pass `last-prompt` to slice the most recently finalized prompt, `last` for the most recent session, `week` / `month` / `all` for cross-session rollups. Use to answer "why did that prompt take so long?" and "which agents are the most expensive in my workflow?". The same card renders automatically at the end of every Stop hook above the 5s noise floor — invoke this skill when you want it on demand or want to slice a different window.
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

The card layout, top to bottom:

1. **Title rule** (`─── Time breakdown ─── 2m 34s · 1 prompt`) — fixed
   anchor for scanning a long Claude Code transcript.
2. **Stacked top-line bar** — three segment chars in a single 30-cell
   bar give the proportions at a glance: `█` agents, `▒` tools, `░`
   idle/model. The percentage legend on the right echoes the segments
   so colour-blind users and no-Unicode terminals still get the
   distribution. Tiny non-zero buckets (1–2%) round up to one cell so
   they stay visible rather than disappearing.
3. **Per-prompt sparkline** (multi-prompt sessions only) — one cell
   per prompt, height encodes that prompt's walltime relative to the
   heaviest prompt in the session. `prompts: ▁█▁▃▆` makes "where did
   the heavy turns land?" answerable at a glance. Hidden on
   single-prompt views (nothing to compare against). Uses U+2581..U+2588
   block elements; normalization always pins the heaviest prompt to U+2588.
4. **Per-bucket rows** — `agents`, `tools`, `idle/model`. Each carries
   its own per-row bar plus the absolute duration and percentage,
   followed by sub-rows for each subagent / tool name with their own
   sub-bar and call count. Sub-row names over 22 chars are truncated
   with U+2026 (`…`) so column alignment stays locked.
5. **Anomaly note** (only when calls were killed mid-flight) — surfaces
   the count of unfinished starts and orphan ends so the user knows the
   aggregates may underestimate.
6. **Insight line** (always one when a rule fires) — at most one
   observation per turn, picked by priority: anomaly first, then
   single-agent / single-tool dominance (>=60%), idle-heavy reassurance
   (>=60% idle on a >=30s turn), tool-churn parallelization hint
   (>=30 calls), diversity fun fact (>=4 distinct subagents),
   substantive-clean reassurance (>=60s with everything paired). The
   engine returns empty for trivial turns where no rule fires; the
   formatter omits the line entirely rather than print a placeholder.

Definitions:

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

## Always-on epilogue

The same card renders automatically as Stop `systemMessage` at the end
of every turn whose walltime is `>= 5 seconds` (the noise floor that keeps
trivial answers off the transcript). Below the floor, the hook stays
silent. A recent stop-guard block within the last 3 seconds also
suppresses the epilogue so the user-facing block message isn't cluttered.
Manual `/ulw-time` invocations bypass the noise floor — if you ask, the
script shows whatever data exists.

## When the data is empty

If the active session has no recorded prompts yet (e.g., this is the first
turn after invoking ULW), the script prints an empty-state line. Run it
again after at least one tool call has completed.

If `time_tracking=off` in `~/.claude/oh-my-claude.conf` (or
`OMC_TIME_TRACKING=off` in the environment), capture is disabled and no
data is recorded. Re-enable in `oh-my-claude.conf` or via `/omc-config`.
