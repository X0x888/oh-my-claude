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

Display the output as-is. Do not summarize, paraphrase, or add interpretation
above what the script already prints — the report is the deliverable.

The report joins data from `~/.claude/quality-pack/`:
- `session_summary.jsonl` — per-session outcome rows (gates fired, skips, serendipity, finding/wave outcomes)
- `serendipity-log.jsonl` — Serendipity Rule applications
- `classifier_misfires.jsonl` — classifier misfire annotations
- `agent-metrics.json` — reviewer invocation counts and verdicts
- `defect-patterns.json` — defect category histogram

If a section comes back empty, it means no data has accumulated for that
window — point the user at `/ulw-status` for an in-flight session view, or
suggest letting more sessions run.
