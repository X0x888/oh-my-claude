---
name: ulw-report
description: Render a markdown digest of recent harness activity — sessions, gate fires, top reviewers, classifier misfires, Serendipity catches, and finding/wave outcomes — over a chosen time window. Use to answer "is the harness actually helping me?".
---
# ULW Report

Parse any argument passed with the skill invocation (stored in `$ARGUMENTS`).
Treat the arguments case-insensitively.

Window selection:
- `last` — the most recent session only
- `week` — sessions in the last 7 days (default when no argument given)
- `month` — sessions in the last 30 days
- `all` — every available row across the cross-session aggregates

Run the report:

```
bash ~/.claude/skills/autowork/scripts/show-report.sh ${ARGUMENTS:-week}
```

Display the output as-is. The report ends with a `## Patterns to consider`
section that surfaces 2–3 actionable interpretations from the data
(high gate-fire density, skip rate, classifier misfires, archetype
convergence, reviewer find rate); when no thresholds trip, the section
emits a clean "no patterns to call out" line. The interpretations are
heuristic, not assertions — treat them as starting points the user can
accept, refine, or ignore. Do not paraphrase or re-summarize above the
script's output — the report itself is the deliverable.

The report joins data from `~/.claude/quality-pack/`:
- `session_summary.jsonl` — per-session outcome rows (gates fired, skips, serendipity, finding/wave outcomes)
- `serendipity-log.jsonl` — Serendipity Rule applications
- `classifier_misfires.jsonl` — classifier misfire annotations
- `agent-metrics.json` — reviewer invocation counts and verdicts
- `defect-patterns.json` — defect category histogram

If a section comes back empty, it means no data has accumulated for that
window — point the user at `/ulw-status` for an in-flight session view, or
suggest letting more sessions run.
