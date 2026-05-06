---
name: ulw-report
description: Render a markdown digest of recent harness activity — sessions, gate fires, top reviewers, classifier misfires, Serendipity catches, and finding/wave outcomes — over a chosen time window. Use to answer "is the harness actually helping me?". Pass `--share` for a privacy-safe shareable card (numbers + distributions only; no prompt text or free-text reasons).
---
# ULW Report

Parse any argument passed with the skill invocation (stored in `$ARGUMENTS`).
Treat the arguments case-insensitively.

Window selection:
- `last` — the most recent session only
- `week` — sessions in the last 7 days (default when no argument given)
- `month` — sessions in the last 30 days
- `all` — every available row across the cross-session aggregates

Modifiers:
- `--share` (v1.31.0) — privacy-safe digest. Sessions / quality-gate-blocks / specialist-dispatches / Serendipity-fires counts plus the top-10 gate-name distribution. Suppresses ALL free-text fields (prompt previews, gate `reason` payloads, Serendipity fix text). Suitable for posting to Slack, PRs, or social. Combine with the window argument: `/ulw-report week --share`.
- `--field-shape-audit` (Bug B post-mortem hardening) — runs a runtime field-shape sanity check over `~/.claude/quality-pack/gate_events.jsonl` and reports any rows whose typed detail fields fail their declared shape contract. Catches Bug B-class leaks (positional misalignment landing prompt-text fragments into typed fields) directly from runtime artifacts instead of relying on source-only review. Bypasses the verbose body — emits a focused audit report and exits 1 if violations are present so it can be wired into CI / pre-release checks. Combine with the window argument: `/ulw-report all --field-shape-audit`. Detail field invariants checked: `state-corruption.archive_path` (path-shaped), `state-corruption.recovered_ts` (Unix epoch), `wave-plan.{wave_idx,wave_total,finding_count}` (non-negative int), `finding-status.{finding_id,finding_status}` (F-NN regex + enum), `bias-defense.directive` (enum). Other gates today have no typed detail invariants and pass through bounded only by the per-event 1024-char value cap (256 for state-corruption).
- `--sweep` (v1.36.0) — fold currently-active session dirs (under `~/.claude/quality-pack/state/`) into the in-memory view this report uses. Closes the gap where `/ulw-report` run during an active session missed that session's gate events because `session_summary.jsonl` / `gate_events.jsonl` only populate at the daily TTL sweep. Read-only: never writes to the cross-session ledger and never claims (deletes) the source dirs. Synthesizes per-session `session_summary` rows using the same jq formula as `sweep_stale_sessions` and tags them `_live: true` for downstream consumers. Combine with the window argument: `/ulw-report --sweep last` (peek at the active session) or `/ulw-report --sweep week` (active session merged into 7-day rollup). Banner line `[--sweep] Including N active session(s) in this view (read-only; ledger not modified).` prefaces the report so the user knows the cross-session aggregate was extended on the fly.

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
