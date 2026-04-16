# Compaction Continuity

When Claude Code compacts a session, preserve the working state instead of producing a generic recap.

## What To Preserve

- The user's active objective and the exact deliverable they want.
- Accepted decisions, constraints, and rejected alternatives that still matter.
- The current task state: completed steps, remaining steps, and the immediate next action.
- Coding: files changed, important commands run, verification evidence, review status, blockers, and unresolved risks.
- Writing or research: audience, tone, format, thesis, outline state, factual constraints, sources used, and open questions.
- Operations or assistant work: deadlines, owners, action items, pending decisions, dependencies, and follow-up obligations.
- Any specialist conclusions that materially changed the direction of work.

## How To Summarize

- Favor explicit working state over vague narrative.
- Prefer durable facts over low-value progress chatter.
- Keep the summary concise but operational: someone continuing the task should know exactly where to resume.
- If something is uncertain, label it as uncertain instead of flattening it into a fact.
- Do not lose user preferences, tone requirements, or audience requirements if they still affect the output.

## Memory Sweep Before Compact

A compact is the highest-cost moment for forgetting: a long session is about to lose granularity. Before the compact completes, scan the session for cross-session auto-memory candidates and write them to `memory/` files alongside the in-session preservation above. The auto-memory rule in `auto-memory.md` names the triggers and file conventions; this file reminds you that compact boundaries are one of two moments to apply that rule — the other is session stop.

Prioritize writing when the session contained any of:
- A confirmed or corrected workflow preference the user articulated (candidate for `feedback_*.md`).
- A revealed project constraint, stakeholder, or deadline not derivable from code (candidate for `project_*.md`).
- An external system reference (Linear, Grafana, Slack channel, doc URL) that future sessions should look at (candidate for `reference_*.md`).
- A user-role or tooling detail that will shape future collaboration (candidate for `user_*.md`).

If nothing in the session meets the memory-save threshold, skip the write. The goal is durable signal, not universal logging.
