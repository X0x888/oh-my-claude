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

`run.sh validate` checks scenario schema. `run.sh score <result.json>`
scores a captured run artifact against the matching scenario. Result
artifacts are intentionally simple JSON so they can be produced by a
future transcript runner, CI job, or manual pilot without coupling this
repo to a Claude Code automation API.
