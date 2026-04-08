# Architecture

oh-my-claude is a harness that wraps Claude Code's lifecycle events with bash hooks. Every prompt, tool use, compaction, resume, and stop attempt passes through scripts that classify intent, inject context, track state, and enforce quality gates. There is no daemon, no runtime, and no external service. The entire system is bash scripts sourcing a shared library, communicating through a JSON state file.

---

## Components

### Orchestration

**`skills/autowork/SKILL.md`** -- Master skill definition. Entry point for `/ulw`, `/autowork`, `/ultrawork`, and `/sisyphus` commands. Defines thinking requirements (plan before acting, reflect after results, no mechanical tool chaining), operating rules (classify intent, classify domain, route to specialists), and execution style (incremental changes, mandatory review, no premature stopping). Sets `disable-model-invocation: true` and `model: opus`.

### Shared Library

**`skills/autowork/scripts/common.sh`** (~426 lines) -- Every hook script sources this file. It provides:

- **JSON state management**: `write_state(key, value)`, `read_state(key)`, `write_state_batch(k1, v1, k2, v2, ...)` for atomic multi-key updates. All operations use jq with atomic temp-file-then-mv writes to prevent corruption.
- **Intent classification**: `classify_task_intent(text)` -- returns one of 5 categories (see classification order below). Delegates to `is_continuation_request`, `is_checkpoint_request`, `is_session_management_request`, `is_imperative_request`, and `is_advisory_request`.
- **Domain scoring**: `infer_domain(text)` -- scores prompt text against keyword lists for 6 domains (coding, writing, research, operations, mixed, general). Uses `count_keyword_matches` with grep to count occurrences. Highest score wins. "Mixed" requires coding involvement with a second domain scoring at least 40% of the primary.
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
7. If the prompt contains `ultrathink`, appends a deeper investigation directive.
8. Emits the assembled context via `hookSpecificOutput.additionalContext`.

**`skills/autowork/scripts/stop-guard.sh`** (~133 lines) -- **Stop hook**. Hard quality gate that can block Claude from stopping. Three independent checks:

1. **Advisory inspection gate**: If the task is advisory over a codebase (coding or mixed domain) and no code inspection (`last_advisory_verify_ts`) or build/test verification (`last_verify_ts`) was detected, blocks the stop. Cap: 1 block.
2. **Session handoff gate**: If the last assistant message contains deferral language ("ready for a new session", "next wave", "next phase") and the user did not request a checkpoint, blocks the stop. Cap: 2 blocks.
3. **Review/verification gate**: If files were edited (`last_edit_ts` set) but review (`last_review_ts`) or verification (`last_verify_ts`) are missing or stale (timestamp earlier than last edit), blocks the stop. Review is checked for all domains; verification is only checked for coding and mixed. Cap: 3 blocks.

The block caps prevent infinite loops. After the cap, Claude is allowed to stop even if gates are unsatisfied.

**`skills/autowork/scripts/mark-edit.sh`** -- **PostToolUse hook** for Edit, Write, and MultiEdit. Records `last_edit_ts`, resets all guard block counters and the stall counter. Excludes internal Claude paths (projects, state, tasks, todos, transcripts, debug) from tracking. Logs edited file paths to `edited_files.log`.

**`skills/autowork/scripts/record-verification.sh`** -- **PostToolUse hook** for Bash. Checks if the command matches a test/build/lint pattern (npm test, cargo test, pytest, vitest, eslint, tsc, etc.). If so, records `last_verify_ts` and the command text, and resets guard counters.

**`skills/autowork/scripts/record-advisory-verification.sh`** -- **PostToolUse hook** for Grep and Read. During advisory tasks, records `last_advisory_verify_ts` when a non-internal file is read or searched. Also implements stall detection: increments a counter on each Read/Grep call, and at 12 consecutive calls without an edit, test, or agent delegation, injects a stall-check nudge.

**`skills/autowork/scripts/reflect-after-agent.sh`** -- **PostToolUse hook** for Agent. After an agent returns, injects a reflection prompt telling Claude to verify the agent's highest-impact claims against actual code before relying on them. For advisory tasks, additionally warns not to deliver the final report until all exploration agents have returned.

**`skills/autowork/scripts/record-reviewer.sh`** -- **SubagentStop hook** for quality-reviewer and editor-critic agents. Records `last_review_ts` and resets stop guard counters when a reviewer agent completes.

**`skills/autowork/scripts/record-subagent-summary.sh`** -- **SubagentStop hook** (all agents). Appends the agent's type and last assistant message to `subagent_summaries.jsonl` (capped at 16 entries).

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
  |-- Inject via hookSpecificOutput.additionalContext
  |
  v
Claude processes with injected context
  |
  |-- [PostToolUse: Edit/Write/MultiEdit] mark-edit.sh
  |     Records last_edit_ts, resets guard counters
  |
  |-- [PostToolUse: Bash] record-verification.sh
  |     Detects test/build/lint commands, records last_verify_ts
  |
  |-- [PostToolUse: Grep/Read] record-advisory-verification.sh
  |     Tracks code inspection, detects stalls (12+ reads without progress)
  |
  |-- [PostToolUse: Agent] reflect-after-agent.sh
  |     Injects reflection prompt, warns about premature synthesis
  |
  |-- [SubagentStop] record-subagent-summary.sh
  |     Logs agent conclusions to subagent_summaries.jsonl
  |
  |-- [SubagentStop: quality-reviewer/editor-critic] record-reviewer.sh
  |     Records last_review_ts
  |
  v
Claude attempts to stop
  |
  v
[Stop hook] stop-guard.sh
  |-- Check 1: Advisory over codebase without code inspection? -> Block (max 1)
  |-- Check 2: Deferral language without user-requested checkpoint? -> Block (max 2)
  |-- Check 3: Edits without review or verification? -> Block (max 2)
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
| `last_edit_ts` | Epoch timestamp of the last file edit |
| `last_verify_ts` | Epoch timestamp of the last test/build/lint verification |
| `last_verify_cmd` | The verification command that was run |
| `last_review_ts` | Epoch timestamp of the last reviewer agent completion |
| `last_advisory_verify_ts` | Epoch timestamp of the last code inspection during advisory tasks |
| `last_assistant_message` | Claude's last response (captured at stop hook entry) |
| `last_assistant_message_ts` | Epoch timestamp of the above |
| `last_user_prompt` | Raw text of the last user prompt |
| `last_user_prompt_ts` | Epoch timestamp of the above |
| `last_meta_request` | Normalized text of the last advisory/session-mgmt/checkpoint prompt |
| `stop_guard_blocks` | Number of times the review/verify gate has blocked (cap: 2) |
| `session_handoff_blocks` | Number of times the deferral gate has blocked (cap: 2) |
| `advisory_guard_blocks` | Number of times the advisory inspection gate has blocked (cap: 1) |
| `stall_counter` | Consecutive Read/Grep calls without a progress action |
| `resume_source_session_id` | Session ID of the session this one was resumed from |
| `last_compact_trigger` | What triggered the last compaction |
| `last_compact_request_ts` | When the last compaction was requested |

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
