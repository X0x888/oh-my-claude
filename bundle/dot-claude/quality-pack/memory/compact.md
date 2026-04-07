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
