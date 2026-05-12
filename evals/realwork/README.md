# Real-Work ULW Eval Harness

This directory defines outcome-oriented evaluations for the question the
unit tests cannot answer: given a minimal `/ulw` prompt, did Claude Code
ship real work that is correct, reviewed, verified, and efficient?

Each scenario in `scenarios/*.json` declares:

- the minimal user prompt
- expected risk tier
- required outcome signals
- token/tool/time budgets
- acceptance checks a result artifact must report
- a `fixture` path (relative to this dir) where the scenario should be
  run — fixtures are user-provided; the harness does not bundle them
  because realistic fixtures are project-specific and would bloat the
  install footprint

## Commands

| Command | What it does |
|---|---|
| `bash run.sh list` | Pretty-prints every scenario id / risk / prompt |
| `bash run.sh validate` | Schema-validates every scenario JSON |
| `bash run.sh score <result.json>` | Scores a result artifact against the matching scenario, prints `{score, pass, missing_outcomes, budget_failures}` |
| `bash result-from-session.sh --scenario <id> [--session <sid>]` | **v1.39.0 W3** — synthesizes a result artifact from a real session's telemetry (session_state.json + timing.jsonl + findings.json + edited_files.log) |

## End-to-end usage

```bash
# 1. Run /ulw against your fixture with the scenario's prompt.
cd path/to/your-fixture
# (in Claude Code) /ulw fix the off-by-one counter bug and add regression coverage

# 2. After the session ends, synthesize a result and score it.
bash evals/realwork/result-from-session.sh \
  --scenario targeted-bugfix > result.json
bash evals/realwork/run.sh score result.json
# => {"scenario_id":"targeted-bugfix","score":100,"pass":true,"missing_outcomes":[],"budget_failures":[]}
```

The producer reads from `~/.claude/quality-pack/state/<latest-session>/`
by default. Override with `--session <sid>` or `--state-root <dir>` for
CI runs or batch scoring.

Result artifacts are intentionally simple JSON so they can be produced
manually for sanity checks, by `result-from-session.sh` for real
sessions, or by a future transcript runner for replay. No coupling to a
Claude Code automation API.
