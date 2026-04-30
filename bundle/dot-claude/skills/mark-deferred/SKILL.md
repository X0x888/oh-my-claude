---
name: mark-deferred
description: Mark all pending discovered-scope findings as deferred with a one-line reason that names a concrete WHY. Use when the discovered-scope gate flags advisory-specialist findings you have consciously decided cannot ship in this session — typically because they require a separate specialist, a database migration, a stakeholder decision, or context not yet loaded. Each deferred row is timestamped and the reason is recorded so the gate stops blocking and `/ulw-report` can audit deferral patterns later. **Prefer wave-append over deferral when the finding is same-surface to your active work** — see *When NOT to use* below.
argument-hint: <reason — must include WHY (requires X / blocked by Y / superseded by Z / duplicate / awaiting stakeholder)>
---
# Mark Pending Findings Deferred

Bulk-update every `pending` finding in the current session's `discovered_scope.jsonl` to `deferred` with a one-line reason. The discovered-scope gate counts only `pending` rows, so once you defer the rest, your next stop attempt passes through. The deferred rows are kept (not deleted) so you and `/ulw-report` can see what was triaged versus what was shipped.

**Important — `/mark-deferred` is the LAST resort, not the first.** The discovered-scope gate offers four ways to address a finding:

1. **Ship it** — fix the finding in this session and reference the file/line in your summary. Default for findings on surfaces you are already loaded into. Cheapest option when the fix is bounded.
2. **Append to the active wave plan** (when one exists) — `record-finding-list.sh add-finding <<< '{"id":"F-NNN","summary":"...","severity":"...","surface":"..."}'` then `record-finding-list.sh assign-wave <idx> <total> <surface> F-NNN`. Use when the finding is same-surface as work you are already doing OR a natural follow-on wave. Phase 8 of `/council` documents this; the same pattern works for any session with a wave plan.
3. **Defer with a named WHY** (this skill) — use when the finding genuinely cannot ship in this session and there is no wave plan to append to.
4. **Call it out as known follow-up risk** in your summary — use when the finding is observation-only and no follow-up commitment is being made.

The skill rejects low-information reasons that have historically been used to silently skip work. "Out of scope" alone, "not in scope" alone, "follow-up" alone, or any reason without a named *requires X / blocked by Y / superseded by Z* clause is rejected — write the WHY explicitly so future sessions can see what the deferral is *waiting on*.

## Usage

The user provides a reason that names the WHY: `/mark-deferred requires database migration outside this session's surface — open ticket then schedule wave 2`

Acceptable reason shapes:
- `requires <named context>` — `requires database migration`, `requires legal review`, `requires stakeholder X to confirm pricing`
- `blocked by <named blocker>` — `blocked by F-042 fix shipping first`, `blocked by upstream dependency upgrade`
- `superseded by <named successor>` — `superseded by F-051 which covers the same surface`
- `duplicate` / `obsolete` / `superseded` — single-token self-explanatory reasons (allowlist)
- `awaiting <named event>` — `awaiting telemetry from canary`, `awaiting user policy decision`
- `pending #<issue>` / `pending wave N` — references to a tracked successor

**Rejected** (the script will error and ask you to be specific):
- `out of scope` (no WHY — what makes it out of scope?)
- `not in scope` (same)
- `follow-up` (no WHY — what is the follow-up waiting on?)
- `separate task` (same — what task, when?)
- `later` / `not now` (no WHY)
- `low priority` (rank, not reason — the gate already shows severity)

## Steps

1. Take the user's reason text (everything after `/mark-deferred`). If nothing was provided, refuse and ask for a reason — silent deferral is the anti-pattern this skill exists to make explicit.
2. Run the helper script with the reason as the single argument:

   ```bash
   bash ~/.claude/skills/autowork/scripts/mark-deferred.sh "REASON_HERE"
   ```

3. The script validates the reason against the require-WHY rule. If rejected, the error message lists acceptable reason shapes — refine the reason and re-invoke.
4. On success, the script prints a one-line confirmation: how many rows were updated, how many were already non-pending. Relay that to the user.
5. Remind the user that: (a) the deferred rows are still recorded so `/ulw-report` can audit them, and (b) if they want to address one of the deferred items later, they can re-open it by editing `discovered_scope.jsonl` directly or by addressing it in their summary.
6. Continue working or attempt to stop.

## When NOT to use

- **The findings are same-surface to your active work** — append to the wave plan via `record-finding-list.sh add-finding` instead of deferring. The harness has wave-append infrastructure for exactly this case; the butterfly effect (everything in a complex project is connected) means same-surface findings deferred today often reappear as follow-up bugs tomorrow. Reach for wave-append before reaching for deferral.
- **The gate fired but the findings actually *should* ship in this session** — address them in your summary directly with file/line references. The Serendipity Rule (in `core.md`) covers when a verified adjacent defect on the same code path with a bounded fix should be fixed in-session, not deferred.
- **You only want to defer one specific finding by id, not the whole pending set** — open `<session>/discovered_scope.jsonl` directly and edit that one row's `status` and `reason` fields. (The harness exposes a per-row `update_scope_status` helper internally; it is not a slash command, so the file edit is the user-facing path.)
- **The block is from a *different* gate (review, verification, excellence)** — those use `/ulw-skip`, not `/mark-deferred`.
