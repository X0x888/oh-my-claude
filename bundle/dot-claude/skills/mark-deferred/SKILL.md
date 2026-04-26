---
name: mark-deferred
description: Mark all pending discovered-scope findings as deferred with a one-line reason. Use when the discovered-scope gate flags advisory-specialist findings you have consciously decided not to ship in this session — out of scope, separate task, follow-up risk. Each deferred row is timestamped and the reason is recorded so the gate stops blocking and `/ulw-report` can audit deferral patterns later.
argument-hint: <reason>
---
# Mark Pending Findings Deferred

Bulk-update every `pending` finding in the current session's `discovered_scope.jsonl` to `deferred` with a one-line reason. The discovered-scope gate counts only `pending` rows, so once you defer the rest, your next stop attempt passes through. The deferred rows are kept (not deleted) so you and `/ulw-report` can see what was triaged versus what was shipped.

## Usage

The user provides a reason: `/mark-deferred out of scope for v1.16, follow-up after telemetry lands`

The reason should be specific. "deferred" alone is the same as silently skipping; the gate exists to prevent that. Good reasons name *why* the finding is being deferred (separate task, requires different specialist, lower priority than the active work, etc.).

## Steps

1. Take the user's reason text (everything after `/mark-deferred`). If nothing was provided, refuse and ask for a reason — silent deferral is the anti-pattern this skill exists to make explicit.
2. Run the helper script with the reason as the single argument:

   ```bash
   bash ~/.claude/skills/autowork/scripts/mark-deferred.sh "REASON_HERE"
   ```

3. The script prints a one-line confirmation: how many rows were updated, how many were already non-pending. Relay that to the user.
4. Remind the user that: (a) the deferred rows are still recorded so `/ulw-report` can audit them, and (b) if they want to address one of the deferred items later, they can re-open it by editing `discovered_scope.jsonl` directly or by addressing it in their summary.
5. Continue working or attempt to stop.

## When NOT to use

- The gate fired but the findings actually *should* ship in this session — address them in your summary instead.
- You only want to defer one specific finding by id, not the whole pending set — open `<session>/discovered_scope.jsonl` directly and edit that one row's `status` and `reason` fields. (The harness exposes a per-row `update_scope_status` helper internally; it is not a slash command, so the file edit is the user-facing path.)
- The block is from a *different* gate (review, verification, excellence) — those use `/ulw-skip`, not `/mark-deferred`.
