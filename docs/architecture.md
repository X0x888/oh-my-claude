# Architecture

oh-my-claude is a harness that wraps Claude Code's lifecycle events with bash hooks. Every prompt, tool use, compaction, resume, and stop attempt passes through scripts that classify intent, inject context, track state, and enforce quality gates. There is no daemon, no runtime, and no external service. The entire system is bash scripts sourcing a shared library, communicating through a JSON state file.

---

## Components

### Orchestration

**`skills/autowork/SKILL.md`** -- Master skill definition. Entry point for `/ulw`, `/autowork`, `/ultrawork`, and `/sisyphus` commands. Defines thinking requirements (plan before acting, reflect after results, no mechanical tool chaining), operating rules (classify intent, classify domain, route to specialists), and execution style (incremental changes, mandatory review, no premature stopping). Sets `disable-model-invocation: true` and `model: opus`.

### Shared Library

**`skills/autowork/scripts/common.sh`** (~516 lines) -- Every hook script sources this file. It provides:

- **JSON state management**: `write_state(key, value)`, `read_state(key)`, `write_state_batch(k1, v1, k2, v2, ...)` for atomic multi-key updates. All operations use jq with atomic temp-file-then-mv writes to prevent corruption.
- **Intent classification**: `classify_task_intent(text)` -- returns one of 5 categories (see classification order below). Delegates to `is_continuation_request`, `is_checkpoint_request`, `is_session_management_request`, `is_imperative_request`, and `is_advisory_request`.
- **Domain scoring**: `infer_domain(text)` -- scores prompt text against keyword lists for 6 domains (coding, writing, research, operations, mixed, general). Uses `count_keyword_matches` with grep to count occurrences. Highest score wins. "Mixed" requires coding involvement with a second domain scoring at least 40% of the primary.
- **Council evaluation detection**: `is_council_evaluation_request(text)` -- detects broad whole-project evaluation requests that benefit from multi-role perspective dispatch. Uses 5 pattern families with narrowing qualifier guards to avoid false-positives on focused requests.
- **Prompt normalization**: `normalize_task_prompt(text)` -- strips `/ulw`, `autowork`, `ultrawork`, `sisyphus`, and `ultrathink` prefixes.
- **Continuation detection**: `is_continuation_request(text)` -- matches "continue", "resume", "carry on", "keep going", "pick it back up", etc.
- **Helpers**: `truncate_chars(limit, text)`, `trim_whitespace(text)`, `now_epoch`, `is_internal_claude_path(path)`, `is_maintenance_prompt(text)`, `has_unfinished_session_handoff(text)`, `is_execution_intent_value(intent)`.

### Hook Scripts

**`quality-pack/scripts/prompt-intent-router.sh`** (~195 lines) -- **UserPromptSubmit hook**. The master context injector. For every prompt:

1. Reads session ID and prompt text from hook JSON.
2. Classifies intent via `classify_task_intent`.
3. Resets per-turn counters (`stop_guard_blocks`, `session_handoff_blocks`, `advisory_guard_blocks`, `stall_counter`).
4. Preserves or updates `current_objective` depending on intent type.
5. Appends to `recent_prompts.jsonl` (capped at 12 entries).
6. If the prompt contains an activation keyword (`ultrawork`, `ulw`, `autowork`, `sisyphus`), builds a `context_parts` array with:
   - Mode directive (continuation, advisory, session-management, checkpoint, or new execution).
   - Preserved objective and prior assistant state for continuations.
   - Recent specialist conclusions from `subagent_summaries.jsonl`.
   - Thinking directive (plan/reflect requirements).
   - Domain-specific specialist hints (coding, writing, research, operations, mixed, general).
   - Council evaluation guidance (for broad whole-project evaluation requests detected by `is_council_evaluation_request`).
7. If the prompt contains `ultrathink`, appends a deeper investigation directive.
8. Emits the assembled context via `hookSpecificOutput.additionalContext`.

**`skills/autowork/scripts/stop-guard.sh`** -- **Stop hook**. Hard quality gate that can block Claude from stopping. Five independent checks:

1. **Advisory inspection gate**: If the task is advisory over a codebase (coding or mixed domain) and no code inspection (`last_advisory_verify_ts`) or build/test verification (`last_verify_ts`) was detected, blocks the stop. Cap: 1 block.
2. **Session handoff gate**: If the last assistant message contains deferral language ("ready for a new session", "next wave", "next phase") and the user did not request a checkpoint, blocks the stop. Cap: 2 blocks.
3. **Review/verification gate**: If files were edited (`last_code_edit_ts` / `last_doc_edit_ts` set, or legacy `last_edit_ts` for resumed sessions) but review (`last_review_ts` for code, `last_doc_review_ts` for docs) or verification (`last_verify_ts`) are missing or stale, blocks the stop. Doc-only edits route to `editor-critic` instead of `quality-reviewer` and skip the verification requirement. Verification is only checked for coding and mixed domains. Cap: 3 blocks. Block 1 uses the full verbose "FIRST self-assess" message; blocks 2+ use a concise "Still missing: X. Next: Y." form that names only un-ticked items.
4. **Dimension gate**: After the standard review/verify gate passes, a prescribed review sequence is enforced on complex tasks via per-dimension ticks. On each block, the gate message names the specific next reviewer to run rather than making the agent guess.

    - **Trigger**: session has `dimension_gate_file_count`+ unique edited files (default 3, configurable). Below the threshold, the gate is inert.
    - **Required dimensions** (computed from the edit mix):
        - Any code files → `bug_hunt`, `code_quality`, `stress_test`, `completeness`
        - Any doc files → add `prose`
        - At least `traceability_file_count`+ files (default 6) → add `traceability`
    - **Dimension ownership** (one reviewer per dimension; see `AGENTS.md` §"Dimension mapping"):
        - `quality-reviewer` → `bug_hunt`, `code_quality`
        - `metis` → `stress_test`
        - `excellence-reviewer` → `completeness`
        - `editor-critic` → `prose`
        - `briefing-analyst` → `traceability`
    - **Validity**: each tick is timestamped (`dim_<name>_ts`) and considered valid only if the tick epoch is ≥ the relevant edit clock (`last_code_edit_ts` for most dimensions, `last_doc_edit_ts` for `prose`). A post-tick edit implicitly invalidates the dimension without needing explicit clearing.
    - **Resumed sessions**: sessions resumed from pre-dimension-gate state get one free stop (`dimension_resume_grace_used`) before the gate starts enforcing.
    - **Cap**: 3 blocks (`dimension_guard_blocks`). Exhaustion records `dimensions_missing=...` in `guard_exhausted_detail` and falls through to the excellence gate rather than bypassing all checks.
5. **Excellence gate**: After all earlier gates pass, if the session has `excellence_file_count`+ unique edited files and no `last_excellence_review_ts` has been recorded (or it is stale), blocks the stop once to request a fresh-eyes holistic evaluation via `excellence-reviewer`. Cap: 1 block (controlled by `excellence_guard_triggered` flag).

The block caps prevent infinite loops. After the cap, Claude is allowed to stop even if gates are unsatisfied.

**`skills/autowork/scripts/mark-edit.sh`** -- **PostToolUse hook** for Edit, Write, and MultiEdit. Records `last_edit_ts` on every edit (backward compat) and also classifies the path via `is_doc_path`: code edits bump `last_code_edit_ts`, doc edits bump `last_doc_edit_ts`. Maintains cached `code_edit_count` / `doc_edit_count` counters (incremented only on first-time paths via `grep -Fxq` dedup). Resets all guard block counters and the stall counter. Excludes internal Claude paths (projects, state, tasks, todos, transcripts, debug) from tracking. Logs edited file paths to `edited_files.log`.

**`skills/autowork/scripts/record-verification.sh`** -- **PostToolUse hook** for Bash. Checks if the command matches a test/build/lint pattern (npm test, cargo test, pytest, vitest, eslint, tsc, etc.). If so, records `last_verify_ts` and the command text, and resets guard counters.

**`skills/autowork/scripts/record-advisory-verification.sh`** -- **PostToolUse hook** for Grep and Read. During advisory tasks, records `last_advisory_verify_ts` when a non-internal file is read or searched. Also implements stall detection: increments a counter on each Read/Grep call, and at `stall_threshold` consecutive calls (default 12, configurable via `oh-my-claude.conf`) without an edit, test, or agent delegation, injects a stall-check nudge.

**`skills/autowork/scripts/reflect-after-agent.sh`** -- **PostToolUse hook** for Agent. After an agent returns, injects a reflection prompt telling Claude to verify the agent's highest-impact claims against actual code before relying on them. For advisory tasks, additionally warns not to deliver the final report until all exploration agents have returned.

**`skills/autowork/scripts/record-reviewer.sh`** -- **SubagentStop hook** for reviewer and analysis agents (`quality-reviewer`, `editor-critic`, `excellence-reviewer`, `metis`, `briefing-analyst`, plus `superpowers:code-reviewer` / `feature-dev:code-reviewer`). Accepts a reviewer-type argument (`standard|excellence|prose|stress_test|traceability`) that determines which dimensions to tick. Parses a `VERDICT: CLEAN|SHIP|FINDINGS|BLOCK` line from the agent's last message (last match wins via `tail -n 1`, `FINDINGS (0)` treated as CLEAN), falling back to a legacy phrase-based regex when the VERDICT line is absent. Records `last_review_ts`, resets stop guard counters, and on clean reviews calls `tick_dimension` to mark the relevant dimension(s) valid. The excellence path additionally records `last_excellence_review_ts` and preserves `review_had_findings` from the standard review.

**`skills/autowork/scripts/record-pending-agent.sh`** -- **PreToolUse hook** for Agent. Records every agent dispatch to `pending_agents.jsonl` (capped at 32 entries) under the state lock. Used by `pre-compact-snapshot.sh` to render a "Pending Specialists (In Flight)" section, and by `session-start-compact-handoff.sh` to emit a re-dispatch directive on compact resume. Entries are removed by `record-subagent-summary.sh` on `SubagentStop` (FIFO-oldest match by `agent_type`).

**`skills/autowork/scripts/record-subagent-summary.sh`** -- **SubagentStop hook** (all agents). Appends the agent's type and last assistant message to `subagent_summaries.jsonl` (capped at 16 entries). Also removes the FIFO-oldest matching entry from `pending_agents.jsonl` via a line-by-line parser that tolerates malformed JSONL lines.

**`quality-pack/scripts/pre-compact-snapshot.sh`** -- **PreCompact hook**. Snapshots the current working state to `precompact_snapshot.md`: session ID, working directory, workflow mode, domain, intent, objective, last assistant message, recent prompts, specialist conclusions, edited files, and review/verification status.

**`quality-pack/scripts/post-compact-summary.sh`** -- **PostCompact hook**. Combines Claude's native compact summary with the preserved snapshot into `compact_handoff.md`.

**`quality-pack/scripts/session-start-resume-handoff.sh`** -- **SessionStart hook** (resume). Copies session state from the previous session's state directory to the new session. Rehydrates JSON state, JSONL files, and logs. Injects continuation context with preserved objective, domain, workflow mode, specialist conclusions, and domain-specific directives.

**`quality-pack/scripts/session-start-compact-handoff.sh`** -- **SessionStart hook** (compact). Reads the pre-compact snapshot, injects it with a continuation directive and thinking requirements.

### Cognitive Defaults

**`quality-pack/memory/core.md`** -- Loaded into every session via CLAUDE.md. Defines thinking quality standards (reason before acting, diagnose before fixing, track progress), workflow rules (classify intent, classify domain, route to specialists, test after changes, review before stopping), code quality rules (no placeholder stubs, no restating comments), anti-patterns (forbidden behaviors like asking "should I proceed?"), and failure recovery (stop retrying after 3 failures, switch approach or delegate to oracle).

---

## Request Flow

```
User prompt
  |
  v
[UserPromptSubmit hook] prompt-intent-router.sh
  |-- Normalize prompt text (strip /ulw, ultrathink prefixes)
  |-- classify_task_intent() -> execution | continuation | advisory | checkpoint | session_management
  |-- infer_domain() -> coding | writing | research | operations | mixed | general
  |-- Reset per-turn counters (stop_guard_blocks, stall_counter, etc.)
  |-- Preserve or update current_objective based on intent
  |-- Build context_parts array:
  |     - Mode directive (execution, continuation, advisory, checkpoint, or session-mgmt)
  |     - Thinking directive (plan/reflect requirements)
  |     - Domain-specific specialist hints
  |     - Prior specialist conclusions (for continuations)
  |     - Ultrathink directive (if keyword present)
  |     - Council evaluation guidance (if broad project evaluation detected)
  |-- Inject via hookSpecificOutput.additionalContext
  |
  v
Claude processes with injected context
  |
  |-- [PreToolUse: Agent] record-pending-agent.sh
  |     Records agent dispatch to pending_agents.jsonl for compact tracking
  |
  |-- [PostToolUse: Edit/Write/MultiEdit] mark-edit.sh
  |     Records last_edit_ts, resets guard counters
  |
  |-- [PostToolUse: Bash] record-verification.sh
  |     Detects test/build/lint commands, records last_verify_ts
  |
  |-- [PostToolUse: Grep/Read] record-advisory-verification.sh
  |     Tracks code inspection, detects stalls (configurable threshold, default 12)
  |
  |-- [PostToolUse: Agent] reflect-after-agent.sh
  |     Injects reflection prompt, warns about premature synthesis
  |
  |-- [SubagentStop] record-subagent-summary.sh
  |     Logs agent conclusions to subagent_summaries.jsonl
  |
  |-- [SubagentStop: quality-reviewer/editor-critic/metis/briefing-analyst/excellence-reviewer] record-reviewer.sh
  |     Parses VERDICT line, records last_review_ts, ticks dimension(s)
  |
  v
Claude attempts to stop
  |
  v
[Stop hook] stop-guard.sh
  |-- Check 1: Advisory over codebase without code inspection? -> Block (max 1)
  |-- Check 2: Deferral language without user-requested checkpoint? -> Block (max 2)
  |-- Check 3: Edits without review or verification (code/doc clocks)? -> Block (max 3)
  |-- Check 4: Prescribed dimensions missing on complex task? -> Block (max 3)
  |-- Check 5: 3+ files edited without excellence review? -> Block (max 1)
  |-- All checks pass or caps reached -> Allow stop
  |
  v
[On compaction]
  pre-compact-snapshot.sh -> Snapshot state to precompact_snapshot.md
  post-compact-summary.sh -> Merge native summary with snapshot into compact_handoff.md
  |
  v
[On session resume or post-compact restart]
  session-start-resume-handoff.sh -> Copy state from previous session, inject context
  session-start-compact-handoff.sh -> Read snapshot, inject continuation directive
```

---

## State Management

Session state is stored at:

```
~/.claude/quality-pack/state/<SESSION_ID>/
  session_state.json        # Primary key-value state (JSON object)
  recent_prompts.jsonl      # Last 12 user prompts with timestamps
  subagent_summaries.jsonl  # Last 16 agent conclusions
  pending_agents.jsonl      # Currently in-flight agent dispatches (managed by record-pending-agent.sh / record-subagent-summary.sh)
  edited_files.log          # Paths of edited files
  precompact_snapshot.md    # Snapshot created before compaction
  compact_handoff.md        # Combined handoff document
  internal_edits.log        # Edits to internal Claude paths (excluded from tracking)
```

### State keys in `session_state.json`

| Key | Purpose |
|---|---|
| `current_objective` | Normalized task description, preserved across advisory/continuation prompts |
| `task_domain` | Classified domain: coding, writing, research, operations, mixed, general |
| `task_intent` | Classified intent: execution, continuation, advisory, checkpoint, session_management |
| `workflow_mode` | Active mode (currently: `ultrawork` or empty) |
| `last_edit_ts` | Epoch timestamp of the last file edit (any type — backward compat) |
| `last_code_edit_ts` | Epoch timestamp of the last code edit (non-doc path) |
| `last_doc_edit_ts` | Epoch timestamp of the last doc edit (matched by `is_doc_path`) |
| `code_edit_count` | Cached count of unique code files edited this session |
| `doc_edit_count` | Cached count of unique doc files edited this session |
| `last_verify_ts` | Epoch timestamp of the last test/build/lint verification |
| `last_verify_cmd` | The verification command that was run |
| `last_review_ts` | Epoch timestamp of the last reviewer agent completion (any code-side reviewer) |
| `last_doc_review_ts` | Epoch timestamp of the last editor-critic (prose) completion |
| `last_advisory_verify_ts` | Epoch timestamp of the last code inspection during advisory tasks |
| `last_assistant_message` | Claude's last response (captured at stop hook entry) |
| `last_assistant_message_ts` | Epoch timestamp of the above |
| `last_user_prompt` | Raw text of the last user prompt |
| `last_user_prompt_ts` | Epoch timestamp of the above |
| `last_meta_request` | Normalized text of the last advisory/session-mgmt/checkpoint prompt |
| `last_verify_outcome` | Result of the last verification: `passed` or `failed` |
| `last_excellence_review_ts` | Epoch timestamp of the last excellence-reviewer completion |
| `review_had_findings` | Whether the last review reported actionable findings (`true`/`false`) |
| `dim_bug_hunt_ts` | Epoch when `bug_hunt` dimension was last ticked |
| `dim_code_quality_ts` | Epoch when `code_quality` dimension was last ticked |
| `dim_stress_test_ts` | Epoch when `stress_test` dimension was last ticked |
| `dim_prose_ts` | Epoch when `prose` dimension was last ticked |
| `dim_completeness_ts` | Epoch when `completeness` dimension was last ticked |
| `dim_traceability_ts` | Epoch when `traceability` dimension was last ticked |
| `stop_guard_blocks` | Number of times the review/verify gate has blocked (cap: 3) |
| `dimension_guard_blocks` | Number of times the dimension gate has blocked (cap: 3) |
| `dimension_resume_grace_used` | Whether the one-shot resumed-session dimension-gate grace has been used (`1` or empty) |
| `session_handoff_blocks` | Number of times the deferral gate has blocked (cap: 2) |
| `advisory_guard_blocks` | Number of times the advisory inspection gate has blocked (cap: 1) |
| `excellence_guard_triggered` | Whether the excellence gate has already fired this session (`1` or empty) |
| `guard_exhausted` | Epoch timestamp when guard caps were reached and stop was allowed |
| `guard_exhausted_detail` | Diagnostic string showing which gates were still unsatisfied at exhaustion |
| `stall_counter` | Consecutive Read/Grep calls without a progress action |
| `resume_source_session_id` | Session ID of the session this one was resumed from |
| `last_compact_trigger` | What triggered the last compaction |
| `last_compact_request_ts` | When the last compaction was requested |
| `last_compact_rehydrate_ts` | When the post-compact SessionStart hook last read the handoff |
| `last_compact_summary` | Native compact summary captured from `PostCompact` |
| `last_compact_summary_ts` | When the native compact summary was captured |
| `just_compacted` | `1` if a PostCompact just fired and the next `UserPromptSubmit` should bias toward continuation; single-use, cleared on first read |
| `just_compacted_ts` | Epoch when `just_compacted` was set; 15-minute staleness window |
| `review_pending_at_compact` | `1` if a quality review was pending when the last compact fired; drives the "MUST run quality-reviewer" directive in the compact-resume injection |
| `compact_race_count` | Number of back-to-back compactions where the prior snapshot had not yet been consumed (diagnostic telemetry) |

---

## Compaction Continuity

When Claude Code compacts a session — either automatically when the context budget is approaching the limit, or manually via `/compact` — the harness runs three hooks to preserve working state:

1. **`PreCompact`** → `pre-compact-snapshot.sh`: writes `precompact_snapshot.md` with objective, domain, intent, last assistant message, recent prompts, active plan, edited files, review/verify status, pending specialists, and a `review_pending_at_compact` flag. Back-to-back compactions archive an unconsumed prior snapshot as `precompact_snapshot.<mtime>.md` (retained up to 5 files).

2. **`PostCompact`** → `post-compact-summary.sh`: reads Claude Code's `.compact_summary` field (or emits a fallback when empty), combines it with the snapshot into `compact_handoff.md`, and sets a `just_compacted` flag so the next `UserPromptSubmit` can bias classification toward continuation. `HOOK_DEBUG=true` dumps the raw hook JSON to `compact_debug.log` for schema diagnosis.

3. **`SessionStart` (source=compact)** → `session-start-compact-handoff.sh`: injects the handoff document via `additionalContext`, with a directive stack that re-asserts ultrawork mode, lists any in-flight specialist dispatches for re-dispatch, and enforces pending-review requirements.

Pending specialist tracking uses a new `PreToolUse` hook (`record-pending-agent.sh`) matched on the `Agent` tool. Every dispatch appends to `pending_agents.jsonl`; every `SubagentStop` removes the FIFO-oldest entry matching the `subagent_type`. This is a per-type counter — same-type concurrent dispatches cannot be distinguished, but the count remains accurate.

On `/ulw-off`, `ulw-deactivate.sh` clears the compact-continuity flags and deletes `pending_agents.jsonl` so stale state from a deactivated session cannot bleed into a later compact resume.

---

## Intent Classification Order

The classification order in `classify_task_intent()` is a protected design decision. Changing it affects routing accuracy across all prompts. The order:

1. **Continuation** (`is_continuation_request`) -- "continue", "resume", "carry on", "keep going", "pick it back up". Matched first because continuation prompts often contain advisory-like words ("continue where you left off?") that would otherwise misclassify.

2. **Checkpoint** (`is_checkpoint_request`) -- "checkpoint", "pause here", "stop here", "for now", "wave 1 only", "first phase only". Explicit user requests for phased delivery.

3. **Session management** (`is_session_management_request`) -- Questions about session strategy: "should I start a new session?", "is the context budget okay?". Requires both session-related keywords AND question-form syntax.

4. **Imperative** (`is_imperative_request`) -- Polite commands: "can you fix...", "please implement...", "go ahead and...", "I need you to...". Checked BEFORE advisory because "can you fix the bug?" is an action request, not advice-seeking. The verb list covers ~40 common action verbs.

5. **Advisory** (`is_advisory_request`) -- Questions and opinion-seeking: "should we...", "what do you think...", "is it better to...", "pros and cons". Only matched if none of the above patterns triggered first.

6. **Default: execution** -- If nothing else matches, the prompt is treated as a direct execution request.

---

## Domain Scoring

`infer_domain()` scores the prompt text against four keyword lists using case-insensitive grep:

- **Coding**: ~35 keywords (bug, fix, refactor, implement, component, endpoint, API, schema, deploy, docker, etc.)
- **Writing**: ~20 keywords (draft, essay, article, report, proposal, email, manuscript, cover letter, etc.)
- **Research**: ~20 keywords (research, investigate, analyze, compare, benchmark, audit, evaluate, etc.)
- **Operations**: ~15 keywords (plan, roadmap, timeline, agenda, meeting, follow-up, checklist, prioritize, etc.)

Each domain gets a score equal to the number of keyword matches. The domain with the highest score wins. If all scores are zero, the domain defaults to `general`.

**Mixed domain**: Triggered when coding has a nonzero score and a second domain scores at least 40% of the primary domain's score. This captures prompts like "research the API options and implement the best one" where both research and coding are significant.
