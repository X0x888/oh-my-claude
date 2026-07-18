# Real-Work ULW Eval Harness

This directory defines outcome-oriented evaluations for the question the
unit tests cannot answer: given a minimal `/ulw` prompt, did Claude Code
ship real work that is correct, reviewed, verified, and efficient across
coding, design/UI, native artifact workflows (workbook/deck/docx),
mixed code+non-code,
quantitative/data-analysis, regulated/high-stakes professional work,
writing, research, scholarly, operations, and advisory work?

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
| `bash arms.sh doctor / validate / list-probes` | **v1.48 W1** — counterfactual arm runner health, probe schema check, probe inventory |
| `bash arms.sh campaign --probe <id> [--runs N]` | Runs a probe's prompt through real headless sessions under every arm (full / trimmed-\* / bare) and prints the delta report |
| `bash arms.sh report [--probe <id>] [--claims]` | Aggregates run records into per-arm outcome rates + cost medians; `--claims` emits a `claims.md`-ready ledger row |
| `bash pairwise.sh validate [probe.json]` | Validates the five-axis blind-comparison protocol, judge schema, calibration cases, and one or every quality probe |
| `bash pairwise.sh compare --probe <id> --baseline <summary.json> --challenger <summary.json> --baseline-harness <checkout> --challenger-harness <checkout> --out <dir>` | Binds both arms to evaluator-verified Git identities, packages matched artifacts anonymously, applies critical-check vetoes, judges both A/B orders, and writes one pair receipt |
| `bash pairwise.sh report <receipt.json>...` | Aggregates pair receipts, dimension margins, scope creep, hard failures, candidate economics, and separately metered judge spend |
| `bash pairwise.sh claim-check <receipt.json>...` | Recomputes the campaign from sealed raw pair receipts and fails unless it clears the preregistered thresholds in `quality-claims.md` |

## Counterfactual arms (v1.48 W1)

`run.sh score` answers "did a ULW session hit its own targets?" —
`arms.sh` answers the question that layer structurally cannot: **did the
harness beat no-harness on the same task?** Each `probes/*.json` targets
one mechanism (the no-defer will-contract, the anti-shallow-thinking
scaffold, the doctrine chain's cost) with a task prompt, a bundled
fixture, two-or-more arms, and ground-truth checks executed against the
workspace after the run — never against harness telemetry, which a bare
arm does not produce. Results accumulate as receipts in
[`claims.md`](claims.md), the subtraction criterion for future
doctrine/gate growth.

Arms are sandboxed installs (`TARGET_HOME` + `CLAUDE_CONFIG_DIR` + `HOME`
isolation — nothing touches your live `~/.claude` or its ledgers).
Sandboxes never inherit interactive login; real campaigns need a one-time
`claude setup-token` (then `export CLAUDE_CODE_OAUTH_TOKEN=...`) or an
`ANTHROPIC_API_KEY`. `tests/test-realwork-arms.sh` exercises the whole
pipeline with a mock binary — zero spend. Probe fixtures under
`fixtures/probes/` are bundled (tiny, purpose-built); the 20 realistic
scenarios' fixtures remain user-provided as documented above.

## Blind pairwise quality campaigns

`pairwise.sh` is the empirical claim layer for the perfectionist contract.
It compares matched baseline and challenger artifacts on five independent
axes: deliberate, distinctive, coherent, visionary, and complete. Critical
ground-truth failures veto aesthetic preference. Otherwise, the read-only
judge sees anonymous `A` and `B` artifact packages in both presentation
orders; a position-sensitive disagreement collapses to a tie rather than a
manufactured win.

The shipped portfolio contains six preregistered probes and six real,
deterministic fixture packages across coding,
control, writing, design, research, and quantitative work. At three paired
runs per probe in both balanced and economy tiers, a complete campaign yields
36 observations and can clear the fixed 30-pair / six-domain / two-tier floor
without inventing post-hoc probes.

Every quality probe's `campaign.candidate_summary_contract` requires the
producer to emit all of the following before comparison:

```json
{
  "probe_id": "quality-config-diagnostics",
  "provenance": {
    "prompt_hash": "<sha256>",
    "fixture_hash": "<sha256>",
    "source_hash": "<sha256>",
    "model": "<full-model-id>",
    "model_tier": "balanced",
    "harness_role": "baseline",
    "harness_hash": "<sha256>"
  },
  "artifact_dir": "path/to/artifact-package",
  "economics": {
    "cost_usd": 1.25,
    "wall_seconds": 120,
    "tokens": {
      "input": 100,
      "output": 50,
      "cache_read": 500,
      "cache_creation": 20
    }
  }
}
```

The prompt, fixture, starting source, full model id, and model tier must match
between arms. A producer must label each summary `baseline` or `challenger`, but
that label and its `harness_hash` are not trusted as identity evidence. The
evaluator requires two explicit, distinct, clean Git checkouts and derives each
hash itself as SHA-256 over the normalized repository slug, exact commit, and
exact tree. A missing checkout, uncommitted or untracked drift, repository
mismatch, wrong role, or producer hash mismatch fails before artifact judging.

[`harness-identities.json`](harness-identities.json) is the canonical campaign
authority. It pins the exact pre-Definition baseline commit and tree; the
challenger must be a different descendant, must contain the feature's required
surfaces, and—under the canonical policy—must be the evaluator repository
checkout itself. That baseline is the committed repository source at the start
of the Definition-of-Excellent work, including unrelated improvements already
present then; an older locally installed SHA is deployment state, not the
counterfactual source boundary. The manifest also names feature surfaces that
must be absent from that baseline and present in the challenger. The complete
manifest snapshot, manifest hash, authority
(`canonical` or `custom`), and both exact identities are frozen into schema-v3
pair manifests, receipts, and reports. Default `claim-check` accepts one
coherent canonical identity campaign only and rebinds its challenger identity
to the current clean evaluator checkout, so producer-selected hashes and
custom evaluator-development manifests cannot satisfy a release claim.

Token counts are exact non-negative integers in the four Claude usage buckets;
an inferred total is not accepted. The artifact directory must contain at
least one file, is copied and content-hashed before judging, and cannot contain
symlinks. Each judge call runs from a disposable workspace that exposes only
its anonymous `A` and `B` packages—not the durable role map or opposite order.
The runner hashes the shipped fixture and its starting `source/` tree, copies
candidate bytes before evaluation, and executes only fixture-owned declarative
check rules. Candidate-supplied check booleans are invalid input. Pair manifests
and receipts are canonicalized and SHA-256 sealed; reports verify those seals
and reject duplicate artifact-pair identities even when their seeds differ.

Each `fixtures/quality/<probe>/manifest.json` maps every preregistered hard-check
ID to one or more non-executable rules. The closed rule vocabulary is
`path_exists`, `file_contains_all`, `file_excludes_all`, `json_equals`,
`same_as_fixture`, and `file_count_at_most`. Validation rejects missing
fixtures, symlinks, path traversal, unknown rule types, missing check IDs, and
manifests whose check set differs from the probe. These rules intentionally
cover objective invariants; the blind judge remains responsible for qualitative
distinctions that cannot be reduced to mechanical checks.

The exact campaign flow is:

```bash
# Zero-spend protocol validation and adversarial regression net.
bash evals/realwork/pairwise.sh validate
bash tests/test-realwork-pairwise.sh

# Run after producing matched candidate summaries and artifact packages.
# The baseline path must be a clean checkout at the manifest-pinned commit;
# the challenger path must be the clean release-candidate checkout.
bash evals/realwork/pairwise.sh compare \
  --probe quality-config-diagnostics \
  --baseline campaign/baseline-summary.json \
  --challenger campaign/challenger-summary.json \
  --baseline-harness campaign/checkouts/pre-definition \
  --challenger-harness "$PWD" \
  --out campaign/pair-001

# Repeat across preregistered domains, tiers, and seeds, then aggregate.
bash evals/realwork/pairwise.sh report \
  campaign/pair-*/receipt.json > campaign/report.json

# This is the release-claim gate. It recomputes from raw receipts; a report
# cannot be substituted for them.
bash evals/realwork/pairwise.sh claim-check campaign/pair-*/receipt.json

# The same receipt can be included in the maintainer release-readiness audit.
bash tools/verify-project-readiness.sh \
  --pairwise-receipt campaign/pair-001/receipt.json \
  --pairwise-receipt campaign/pair-002/receipt.json
```

`arms.sh` and `pairwise.sh` deliberately answer different questions. The arms
runner measures causal harness contribution using its own probe format;
pairwise consumes artifact-level candidate summaries from a matched campaign.
Do not relabel an arms receipt as a pairwise receipt, and do not claim measured
quality improvement until the default `claim-check` passes. The current claim
status and preregistered thresholds live in
[`quality-claims.md`](quality-claims.md).

For evaluator development only, `compare --identity-manifest <file>` permits a
custom manifest whose challenger policy is `explicit-checkout-descendant`, and
`claim-check --allow-custom-portfolio` permits small sets of those synthetic
sealed receipts to exercise threshold logic. Such receipts are visibly marked
`authority: custom`. Neither escape is used by a readiness command, and neither
may be used to label release evidence.

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
