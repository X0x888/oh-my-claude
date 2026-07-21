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
| `bash pairwise.sh validate [probe.json]` | Validates the five-axis blind-comparison protocol, judge schema, sealed calibration-contract shape/digest, and one or every quality probe; it does not claim to run live model calibration |
| `bash pairwise.sh campaign-init ... --out <campaign-dir>` | Seals one campaign instance before execution: exact checkout identities, run roster, candidate model, full probe/fixture/source/producer-task bindings, judge schema, and fixed claim thresholds |
| `bash pairwise.sh generate --campaign <campaign-dir> --campaign-run <id> --probe <id> --harness-role baseline\|challenger --harness <checkout> --out <dir>` | Atomically claims the run/arm's first attempt, installs the selected checkout in an isolated HOME, presents the identical explicit deliverable contract, runs the pinned producer CLI, seals telemetry, and snapshots only bounded declared outputs |
| `bash pairwise.sh compare --campaign <campaign-dir> --campaign-run <id> --probe <id> --baseline <summary.json> --challenger <summary.json> --baseline-harness <checkout> --challenger-harness <checkout> --out <dir>` | Requires the campaign-bound first generation attempts, claims the first comparison attempt, packages matched artifacts anonymously, applies critical-check vetoes, judges both A/B orders, and seals one pair receipt |
| `bash pairwise.sh report <receipt.json>...` | Aggregates pair receipts, dimension margins, hard-check noninferiority, scope creep, hard failures, candidate economics, and separately metered judge spend |
| `bash pairwise.sh campaign-seal --campaign <campaign-dir> --out <campaign-receipt.json>` | Freezes the complete first-attempt stage ledger after every manifest run has baseline, challenger, and comparison success receipts |
| `bash pairwise.sh claim-check <receipt.json>... --campaign-receipt <campaign-receipt.json>` | Recomputes the campaign from raw pair receipts and requires the exact sealed first-attempt roster plus the fixed thresholds in `quality-claims.md` |

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
`ANTHROPIC_API_KEY`. `bash evals/realwork/arms.sh validate` performs zero-spend
protocol validation; live arms still require explicit credentials and spend.
Probe fixtures under
`fixtures/probes/` are bundled (tiny, purpose-built); the 20 realistic
scenarios' fixtures remain user-provided as documented above.

## Blind pairwise quality campaigns

`pairwise.sh` is the empirical claim layer for the perfectionist contract.
It compares matched baseline and challenger artifacts on five independent
axes: deliberate, distinctive, coherent, visionary, and complete. Only exact
structural ground-truth failures may veto aesthetic preference. Semantic,
keyword-only, render-marker, and candidate-authored assertions remain useful
diagnostics but have no automatic winner authority. Otherwise, the read-only
judge sees anonymous `A` and `B` artifact packages in both presentation
orders; a position-sensitive disagreement collapses to a tie rather than a
manufactured win.

The shipped portfolio contains six manifest-sealed probes and six real,
deterministic fixture packages across coding, control, writing, design,
research, and quantitative work. Its manifest commits all 36 run IDs: three
paired runs per probe in both balanced and economy tiers, each with an exact
comparison seed and one pinned candidate model. The claim gate requires that
exact roster—not an arbitrary 30-of-36 subset—while the fixed floor of 30
conclusive pairs still allows bounded inconclusive outcomes. The separate
campaign receipt proves that every run/arm/comparison slot was claimed once
before its producer or judge call, preventing selective retry and receipt
cherry-picking within that sealed campaign instance.

Every quality probe's `campaign.candidate_summary_contract` requires a
pointer-only schema-v4 summary emitted by `pairwise.sh generate`:

```json
{
  "schema_version": 4,
  "probe_id": "quality-config-diagnostics",
  "generation_receipt": "generation.json",
  "generation_receipt_hash": "<sha256>",
  "artifact_dir": "artifact"
}
```

The evaluator, not the caller, owns everything authoritative behind that
summary. Before invoking Claude it resolves the exact campaign run, computes a
canonical SHA-256 over the complete probe object (including audience,
constraints, non-goals, task-specific anchors, dimensions, artifact contract,
checks, and campaign), and constructs a producer-visible task that gives both
arms the same prompt, audience, constraints, non-goals, quality anchors,
dimension names, declared filenames and package kinds, plus evaluator-owned
diagnostic descriptions. The receipt binds
the SHA-256 of that complete visible contract, along with the original prompt,
fixture, and starting-source hashes. The evaluator verifies the clean role
checkout, derives its commit/tree identity, and
installs that checkout into a private HOME at the run's model tier. It then
invokes the pinned producer CLI with the run's full candidate model, measures
wall time around the process, captures canonical raw CLI JSON, and derives cost
plus all four usage buckets from that telemetry.
The sealed generation receipt binds those values and explicit probe authority
(`canonical` or `custom`) to the producer session ID, role, model, tier, run,
artifact snapshot, and—when present—the unique campaign instance/policy hash.
Canonical generation requires that campaign binding and accepts only a full-probe hash that
matches the bundled probe with that ID; retaining the ID, prompt, rubric
version, or budgets while changing another rubric field is a custom development
probe, never canonical evidence. A summary cannot be reassigned to another run
after generation, and self-authored economics have no input field.

`candidate_artifacts` is an enforced package contract, not hidden evaluator
knowledge. Every declared kind must
have at least one matching regular file (`rendered_images` additionally requires
a supported image extension); `git_diff` requires a non-empty evaluator-created
`.pairwise/git.diff` plus canonical `.pairwise/changed-paths.json`. The evaluator
reserves `.pairwise` completely: probes cannot declare that path or any
descendant, producers must not create it, and broad globs cannot claim files
under it. Only a declared `git_diff` causes the evaluator to create the two
exact managed files after the producer exits; candidate-authored versions or
other `.pairwise` content reject the generation instead of being reused or
overwritten. Generation seals the fixture workspace's Git HEAD, refs, logical
index entries, config, and
repository identity before the producer call and rejects any producer mutation
of that authority. A fresh evaluator-owned alternate index then compares the
working tree to the captured commit with rename detection disabled, force-
including ignored, untracked, and empty files; the NUL-delimited Git path stream
is converted to sorted JSON without parsing quoted patch headers. This makes
exact changed-path fixture rules structural veto evidence, including both sides
of a rename as deletion plus addition. The evaluator enumerates and sizes
declared paths, managed patch, and changed-path identity against file,
directory-entry, and byte ceilings before copying producer output; bounded
no-follow copies and final snapshot checks enforce the same limits again. The
generated package contains only declared paths plus those two evaluator-managed
files. Missing packages, undeclared role/telemetry metadata, symlinks, special
nodes, stale package hashes, or Git-authority mutation fail before comparison.

[`harness-identities.json`](harness-identities.json) is the canonical campaign
authority. It pins the exact pre-Definition baseline commit and tree; the
challenger must be a different descendant, must contain the feature's required
surfaces, and—under the canonical policy—must be the evaluator repository
checkout itself. That baseline is the committed repository source at the start
of the Definition-of-Excellent work, including unrelated improvements already
present then; an older locally installed SHA is deployment state, not the
counterfactual source boundary. The manifest also names feature surfaces that
must be absent from that baseline and present in the challenger, and pins the
candidate session model plus the complete probe/tier/run-index/seed roster.
`campaign-init` turns that committed policy into a unique sealed campaign
instance before any paid execution. Its policy hash additionally binds the
current baseline/challenger identities, complete probe, fixture,
starting-source and producer-visible-task hashes, judge-schema hash, sealed
calibration-contract hash, and fixed
release thresholds. Fresh `mktemp` entropy participates in the instance ID, so
otherwise identical initializations in repeatable containers cannot collide on
path, PID, and whole-second time alone. Publish that instance policy hash outside the mutable
campaign directory before the first run when independent preregistration is
required; a local SHA-256 seal alone is cooperative tamper evidence, not an
external timestamp or signature. The
complete manifest snapshot, manifest hash, authority (`canonical` or `custom`),
selected campaign run, probe campaign limits, and both exact identities are
frozen into schema-v6 pair manifests, schema-v7 receipts, and schema-v6
reports. Pair manifests also embed the canonicalized complete probe snapshot,
its full-probe hash, and its independent authority. Default `claim-check`
accepts one coherent canonical identity campaign and the exact current bundled
probe-ID/hash roster with every exact run ID only. It also requires a completed
campaign receipt whose output hashes match every supplied generation and pair
receipt, and rebinds its challenger
identity to the current
clean evaluator checkout, so producer-selected hashes, mixed candidate models,
omitted receipts, and custom evaluator-development manifests cannot satisfy a
release claim. Schema-v6 receipts fail closed because they do not retain the
exact raw judge responses needed for portable outcome re-derivation; schema-v5
and earlier receipts additionally lack causal generation receipts and raw
producer telemetry.

Every receipt also freezes the selected probe's `runs_per_arm`, allowed tiers,
and maximum candidate cost/wall ratios. `claim-check` requires every pair to
meet those per-probe ceilings—including the minimal-change control's stricter
1.25x limits—in addition to the campaign-wide median and p95 ceilings. Changing
a probe budget after generation stales the receipt instead of silently applying
a new threshold to old evidence.
The canonical aggregate thresholds are likewise sealed into the campaign policy
and cannot be weakened with `claim-check` flags. Threshold flags are accepted
only with `--allow-custom-portfolio` for evaluator development.

Judge identity is equally explicit. Canonical comparisons use the judge policy
sealed in `harness-identities.json`: the native
`$HOME/.local/bin/claude` install, Claude Code `2.1.212`, and pinned model
`claude-opus-4-8`, including the exact native executable SHA-256. A same-name
PATH stub, replacement binary, different CLI release, convenience model alias,
or other model fails before a canonical judge call. Every pair seals that
policy hash, the resolved executable digest, requested model,
judge-schema hash, and both prompt hashes. Report and claim validation
regenerate the forward and reverse judge prompts from the embedded full probe
snapshot and rehash them, so a coherently re-sealed same-ID rubric substitution
cannot retain canonical authority; judged receipts also bind the model ID
returned by each CLI call. Reports expose mixed identities, and the default
claim gate accepts only one canonical judge identity whose requested and
returned model IDs agree.
The judge identity also pins the exact canonical
[`judge-calibration/cases.json`](judge-calibration/cases.json) digest. Those
four cases are a frozen expected-outcome contract (two automatic controls and
two judge-behavior expectations), not a fabricated receipt for a live judge
run. Changing a case or expected outcome changes judge policy and campaign
identity before new evidence can be admitted.
Custom judges and custom full-probe snapshots remain available with custom
identity manifests for zero-spend evaluator development. Their authority is
reported explicitly, and they cannot become release evidence.
The executable pin is deliberately release-environment-specific. A Claude Code
upgrade requires a reviewed, committed judge-policy update before candidate
generation; changing it after seeing outcomes creates a different campaign.

Token counts are exact non-negative integers in the four Claude usage buckets;
an inferred total is not accepted. Candidate cost and token buckets are
re-derived during generation-receipt validation from the sealed raw CLI JSON;
wall time is evaluator-measured in whole seconds rather than producer-reported.
For ratio gates, two equal zero measurements are parity (`1.0`) at that clock
resolution; a positive challenger measurement over a zero baseline remains
unbounded and fails the ratio gate. Schema-v7 pair
receipts embed both generation receipts and raw producer telemetry plus the
exact raw bytes returned by each judge call. Report and release-claim validation
rehash and reparse both retained judge responses, re-derive every mapped
outcome/evidence/warning field, and independently repeat candidate-economics
derivation without mutable sibling files. The artifact directory must contain
at least one file, is copied and content-hashed before judging, and cannot
contain symlinks, FIFOs, sockets, devices, or other special nodes. Empty
directories are part of the digest. Each regular file is staged with no-follow
semantics, a write limit, and a per-file timeout. The writer opens only an
unpredictable evaluator-owned, single-link staging file below the sealed final
parent; publication uses no-clobber hard-link creation, so a pre-existing
regular file, hardlink, symlink, FIFO, device, or directory at the final name is
never opened or followed. Parent/source inode, link-count, size, and hash seals
are checked around publication. A failed post-link check leaves any extant
final pathname as an explicit failure fence: portable shell has no atomic
compare-inode-and-unlink primitive, so cleanup never risks deleting a foreign
replacement observed after the check. Type/size/tree checks are repeated on the
immutable destination, so a live-source
FIFO/device/symlink swap fails instead of hanging or escaping. File/byte caps,
a hard judge-response byte cap, and a TERM-to-KILL process-group timeout bound
all remaining resource use.
The evaluator parent process and its command-resolution environment are trusted:
`PATH`, shell functions, and the installed `ln`, `cp`, `mv`, `rm`, `find`, `git`,
`jq`, and hashing utilities must not be caller-substituted. The adversarial
boundary starts at installer, producer, judge, and evidence inputs. A caller
that can wrap or replace the parent evaluator's utilities already controls the
evaluator process and is outside this cooperative same-user integrity model.
Directory entries are capped separately, so empty-directory floods cannot
bypass those limits. Safety, hash, and inode-alias traversals stream under an
entry cap and timeout before any sort/dedup step; declared Git path enumeration
also has a raw pre-sort ceiling. Isolated harness installation is bounded by
`OMC_PAIRWISE_HARNESS_INSTALL_TIMEOUT_SECONDS` (300 seconds by default) and
`OMC_PAIRWISE_MAX_INSTALL_LOG_BYTES` (16 MiB by default).
Generation and comparison atomically claim a previously absent output path,
seal the device/inode plus physical path of every evaluator-owned child, and
recheck those seals across custom producer/judge calls. Their evaluator-package
roots and actor-facing child roots have exact typed inventories at every actor
boundary: an installer, producer, or judge cannot pre-create even a
plausibly-named future receipt, telemetry, prompt, or metadata node. Generation
creates its artifact destination only after the producer process group exits;
installer and producer stdout/stderr are captured under private unpredictable
paths and published only after the workspace, harness checkout, executable,
root inventory, and child seals re-attest. Generation receipt and summary files
follow the same private-stage/no-clobber path. Snapshot copying rejects
symlinked or non-physical destination roots.
Manual reconciliation also holds an output-path-specific sibling claim whose
owner record binds PID, process-birth identity, claimant token, and lease
metadata. A live owner excludes contenders; after SIGKILL, a successor retires
only the dead owner generation and can safely reacquire the fixed claim.
Each judge call runs from a disposable workspace that exposes its anonymous `A`
and `B` packages plus an identical hash-checked neutral `INPUT` copy of the
sealed starting `source/` tree—not the fixture manifest, durable role map, or
opposite order. The judge prompt binds that source hash and requires candidate
claims, calculations, and traceability to be checked against `INPUT`, while
still requiring every evidence citation to identify an A/B candidate path. The
judge's stdout/stderr are claimed before invocation in a separate private
capture directory, never in the actor-visible workspace. Raw attempts, parsed
responses, execution metadata, the pair manifest, both prompts, and the final
receipt are single-link/inode/hash bound and no-clobber published; the exact
pair-package inventory and judge executable are checked before and after every
call and again before receipt publication. The
runner copies candidate bytes before evaluation and executes only fixture-owned
declarative check rules. Candidate-supplied check booleans are invalid input. Noncritical
deterministic results are shown to the judge as anonymous A/B diagnostics, but
remain explicitly non-veto evidence. The release gate additionally enforces
hard-check noninferiority: any baseline-pass/challenger-fail check blocks the
claim even when that check is noncritical and the blind judge prefers the
challenger. Pair manifests and receipts are canonicalized and SHA-256 sealed;
reports verify those seals and reject duplicate campaign-run IDs, generation
IDs, producer session IDs, raw telemetry hashes, and generation receipt hashes.
The pair identity deliberately excludes the run ID, while the separate pair ID
binds the run and both generation IDs. Independent runs may therefore produce
the same artifact pair and remain separate causal observations; replaying a run,
generation, session, telemetry record, or receipt still fails.
Baseline and challenger artifact roots must also be physically disjoint from
one another and from both summaries, generation metadata, telemetry, probe,
fixture, identity manifest, output directory, and harness checkouts. Shared
hard-linked files—between roles or between an artifact and any protected input
tree—are rejected to prevent role or evaluator-input leakage.
Before any campaign authorization or semantic comparison read, `compare`
copies each producer-controlled schema-v4 summary, referenced generation
receipt, raw telemetry file, and complete artifact tree into one private sealed
candidate-authority package. The copied artifact hash must equal the frozen
generation receipt. Every subsequent provenance, economics, campaign, package,
and judging decision uses those frozen paths only; replacing any live summary,
generation, telemetry, or artifact after that point cannot create a mixed
generation.
Receipts are intentionally portable within their pinned evaluator version:
`report` and `claim-check` copy each regular non-symlink receipt exactly once
into a private, count/per-file-size/aggregate-size/time-bounded snapshot set,
then validate and aggregate only those frozen bytes. The defaults admit at most
200 receipts, 16 MiB per receipt, and 256 MiB across the complete snapshot set;
evaluator-development overrides are `OMC_PAIRWISE_MAX_RECEIPTS`,
`OMC_PAIRWISE_MAX_RECEIPT_BYTES`, `OMC_PAIRWISE_MAX_RECEIPT_TOTAL_BYTES`, and
`OMC_PAIRWISE_RECEIPT_COPY_TIMEOUT_SECONDS`. Replacing a live path during
validation therefore cannot inject unvalidated aggregation data or make the
aggregator slurp an unbounded permitted set. They validate the sealed
compare-time hashes without requiring mutable sibling candidate/view
directories. Archive the complete pair directory when later byte-level artifact
inspection is desired; editing those convenience snapshots does not rewrite the
historical receipt. A later schema/probe/fixture change deliberately makes the
older receipt stale for a new release claim.

Generation, comparison, campaign initialization/sealing, report, and claim
validation freeze their identity manifest once; later portfolio, checkout,
producer/judge, and publication decisions use that single-link private copy.
`claim-check` also freezes the judge schema, calibration contract, and complete
canonical probe tree before receipt validation, routes all claim computation
through those private copies, and re-attests the live authority immediately
before publishing its decision.
Generation, comparison, and campaign sealing likewise make one bounded private
snapshot of `campaign.json` and use only that policy generation. First-attempt
admission also checks that the live policy still has the exact snapshotted byte
identity. The campaign root is exactly `campaign.json` plus `stages/`; run and
stage directories admit only manifest run IDs, the three fixed stage names, and
one regular `claim.json`. Run parents are sealed before child creation, and
initial/start/success/failure/seal publication uses unpredictable staging and
no-follow publication. Every constructed pair receipt is fully revalidated and must fit the
same report input cap before a campaign stage can be marked successful; the
default cap is 16 MiB and `OMC_PAIRWISE_MAX_RECEIPT_BYTES` changes both sides of
that contract. An explicitly supplied campaign receipt always must have a valid
seal and exact run/stage/output binding, including in custom development mode;
custom mode may still omit the campaign receipt altogether. Portable timeout
watchdogs use private marker directories and require
`OMC_PAIRWISE_TIMEOUT_KILL_GRACE_SECONDS` to be an integer from 1 through 60.

Each `fixtures/quality/<probe>/manifest.json` maps every manifest-sealed hard-check
ID to one or more non-executable rules. The closed rule vocabulary is
`path_exists`, `file_contains_all`, `file_excludes_all`, `json_equals`,
`same_as_fixture`, `file_count_at_most`, and `changed_paths_exact`. Only
`path_exists`, `same_as_fixture`, `file_count_at_most`, and
`changed_paths_exact` may be marked critical; the other
rules are deterministic observations but are too easy to satisfy through
self-attestation or keyword stuffing to decide a winner. Validation rejects missing
fixtures, symlinks, path traversal, unknown rule types, missing check IDs, and
manifests whose check set differs from the probe. These rules intentionally
cover objective invariants; the blind judge remains responsible for qualitative
distinctions that cannot be reduced to mechanical checks.

The exact campaign flow is:

```bash
# Zero-spend protocol and deterministic scoring validation.
bash evals/realwork/pairwise.sh validate

# The baseline path must be a clean checkout at the manifest-pinned commit;
# the challenger path must be the clean release-candidate checkout.
# Keep every campaign artifact OUTSIDE that checkout: canonical identity checks
# reject tracked or untracked campaign output in the challenger tree.
CAMPAIGN_ROOT="$(mktemp -d /tmp/omc-quality-campaign.XXXXXX)"
mkdir -p "$CAMPAIGN_ROOT/checkouts"
BASELINE_REF="$(jq -r '.baseline.git_commit' evals/realwork/harness-identities.json)"
git worktree add --detach "$CAMPAIGN_ROOT/checkouts/pre-definition" "$BASELINE_REF"
OMC_PAIRWISE_JUDGE_MODEL="$(jq -r '.judge.model_id' evals/realwork/harness-identities.json)"
CAMPAIGN_RUN_ID="quality-config-diagnostics-balanced-01"
CAMPAIGN_AUTHORITY="$CAMPAIGN_ROOT/authority"

# Seal a unique campaign instance before any producer/judge call. For an
# independently preregistered study, publish the printed CAMPAIGN_POLICY_HASH
# in an external immutable channel now.
bash evals/realwork/pairwise.sh campaign-init \
  --identity-manifest evals/realwork/harness-identities.json \
  --baseline-harness "$CAMPAIGN_ROOT/checkouts/pre-definition" \
  --challenger-harness "$PWD" \
  --out "$CAMPAIGN_AUTHORITY"

bash evals/realwork/pairwise.sh generate \
  --campaign "$CAMPAIGN_AUTHORITY" \
  --campaign-run "$CAMPAIGN_RUN_ID" \
  --probe quality-config-diagnostics \
  --harness-role baseline \
  --harness "$CAMPAIGN_ROOT/checkouts/pre-definition" \
  --out "$CAMPAIGN_ROOT/generated-baseline-001"

bash evals/realwork/pairwise.sh generate \
  --campaign "$CAMPAIGN_AUTHORITY" \
  --campaign-run "$CAMPAIGN_RUN_ID" \
  --probe quality-config-diagnostics \
  --harness-role challenger \
  --harness "$PWD" \
  --out "$CAMPAIGN_ROOT/generated-challenger-001"

bash evals/realwork/pairwise.sh compare \
  --campaign "$CAMPAIGN_AUTHORITY" \
  --campaign-run "$CAMPAIGN_RUN_ID" \
  --probe quality-config-diagnostics \
  --baseline "$CAMPAIGN_ROOT/generated-baseline-001/summary.json" \
  --challenger "$CAMPAIGN_ROOT/generated-challenger-001/summary.json" \
  --baseline-harness "$CAMPAIGN_ROOT/checkouts/pre-definition" \
  --challenger-harness "$PWD" \
  --judge-model "$OMC_PAIRWISE_JUDGE_MODEL" \
  --out "$CAMPAIGN_ROOT/pair-001"

# Repeat for every committed row under `.portfolio.runs`; the selected row
# fixes probe, tier, candidate session model, run index, and comparison seed.
# Both generations must already bind that row. Seal the complete first-attempt
# ledger, then aggregate the complete roster.
bash evals/realwork/pairwise.sh campaign-seal \
  --campaign "$CAMPAIGN_AUTHORITY" \
  --identity-manifest evals/realwork/harness-identities.json \
  --out "$CAMPAIGN_ROOT/campaign-receipt.json"

bash evals/realwork/pairwise.sh report \
  "$CAMPAIGN_ROOT"/pair-*/receipt.json > "$CAMPAIGN_ROOT/report.json"

# This is the release-claim gate. It recomputes from raw receipts; a report
# cannot be substituted for them.
bash evals/realwork/pairwise.sh claim-check "$CAMPAIGN_ROOT"/pair-*/receipt.json \
  --campaign-receipt "$CAMPAIGN_ROOT/campaign-receipt.json"

# The same receipt can be included in the maintainer release-readiness audit.
bash tools/verify-project-readiness.sh \
  --pairwise-campaign-receipt "$CAMPAIGN_ROOT/campaign-receipt.json" \
  --pairwise-receipt "$CAMPAIGN_ROOT/pair-001/receipt.json" \
  --pairwise-receipt "$CAMPAIGN_ROOT/pair-002/receipt.json"
```

`arms.sh` and `pairwise.sh` deliberately answer different questions. The arms
runner measures causal harness contribution using its own probe format;
pairwise generates and consumes sealed artifact-level candidate receipts from a matched campaign.
Do not relabel an arms receipt as a pairwise receipt, and do not claim measured
quality improvement until the default `claim-check` passes. The current claim
status and sealed thresholds live in
[`quality-claims.md`](quality-claims.md).

For evaluator development only, `compare --identity-manifest <file>` permits a
custom manifest whose challenger policy is `explicit-checkout-descendant`, and
`claim-check --allow-custom-portfolio` permits small sets of those synthetic
sealed receipts to exercise threshold logic. Such receipts are visibly marked
`authority: custom`. Neither escape is used by a readiness command, and neither
may be used to label release evidence. A custom schema-v2 manifest still binds
its selected run/model/tier/seed exactly; authority controls release eligibility,
not whether a declared roster may be ignored. Legacy schema-v1 custom manifests
remain available only for small evaluator-development fixtures.

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
