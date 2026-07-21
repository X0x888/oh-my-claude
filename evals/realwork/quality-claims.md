# Quality-loop outcome receipts

This ledger is for artifact-level counterfactual evidence: the same prompt,
fixture, work-source revision, model, and model tier run through the pre-loop
harness and the quality-loop harness, then judged blind in both A/B orders.
Internal gate telemetry is diagnostic only; it cannot satisfy an outcome claim.
The baseline authority is the committed repository source at the start of this
feature (`14680a955e1ae0e427dbfa641de13051b0cad47d`, tree
`fcb391c3004368d15a264ff16b513733935e0f18`), not the machine's older
`installed_sha`; this preserves every unrelated improvement already in today's
source harness while subtracting the Definition-of-Excellent change itself.

## Sealed release threshold

A campaign may be called a positive receipt only when `pairwise.sh claim-check`
passes all of these fixed thresholds. Canonical claims cannot override them on
the command line; threshold flags require the explicitly non-release
`--allow-custom-portfolio` mode:

- one unique campaign policy was sealed before execution and its complete
  first-attempt receipt covers baseline generation, challenger generation, and
  comparison for every manifest run; every stage output hash must equal the raw
  generation/pair receipt supplied to the claim gate
- every pair is bound by the canonical `harness-identities.json` campaign to
  the same exact pre-feature baseline commit/tree and the same exact clean
  release-candidate commit/tree, judge executable/model policy, and sealed
  calibration-contract digest; custom identity manifests are not release evidence
- the exact 36-run manifest roster is present once each: all six probes ×
  (`balanced`, `economy`) × run indexes 1–3, with no omitted, substituted, or
  duplicate run IDs and with each committed comparison seed
- every candidate comes from an evaluator-owned sealed generation receipt whose
  producer session, canonicalized complete-probe hash and authority,
  prompt/producer-visible-task/fixture/source hashes, exact role checkout, run
  ID, model, model tier, and unique campaign policy/instance were bound before
  CLI invocation; summaries are pointer-only and cannot supply provenance or
  economics
- both producer arms receive the identical explicit deliverable contract,
  including filenames/package kinds, constraints, non-goals, quality anchors,
  dimension names, and evaluator-owned diagnostic descriptions; its full
  visible-text hash is part
  of generation and pair identity
- every canonical pair uses the exact bundled full probe. The digest covers all
  fields, including audience, constraints, non-goals, task-specific anchors,
  dimensions, checks, artifact contract, and budgets; preserving only the probe
  ID, task prompt, rubric version, or budget values is insufficient
- every generation uses the manifest-pinned top-level session model;
  `model_tier` remains the independent harness routing posture, so balanced and
  economy exercise different specialist/escalation behavior under the same
  controlled session model
- at least 30 conclusive independent artifact pairs across at least 6 domains and 2 model tiers
- challenger wins at least 60% and loses at most 20% of conclusive pairs
- the exact two-sided paired sign test (ties excluded) is positive with p <= 0.05
- no sampled domain has a negative challenger win-minus-loss margin
- at least 20 artifact pairs receive a valid five-axis judgment (hard-check vetoes are outcome evidence, not taste judgments)
- at least 4 of the 5 quality dimensions have positive signed margins
- the `visionary` win-minus-loss margin is at least 15 percentage points
- zero challenger critical-check failures
- no deterministic hard-check regression: a check passed by the baseline may
  not fail for the challenger, including noncritical diagnostics that do not
  have automatic winner authority; aggregate challenger passes must be at least
  baseline passes
- zero blocking challenger hard-quality warnings from the blind judge
- zero challenger scope-creep judgments
- complete candidate cost and wall-ratio coverage for every conclusive pair;
  equal zero measurements count as parity (`1.0`) at evaluator clock
  resolution, while a positive challenger over a zero baseline remains
  unbounded and fails coverage
- every pair satisfies its probe's frozen cost and wall ceilings (1.25x for the
  minimal-change control; 1.75x for the other current probes)
- median candidate cost and wall-time ratios are at most 1.75x
- p95 candidate cost and wall-time ratios are at most 2.5x

Order-swapped judge calls collapse to one artifact-pair observation. A position
disagreement is a tie, not two votes. Identical artifacts auto-tie. A critical
ground-truth failure computed from the shipped fixture's deterministic rules
vetoes a judge preference; candidate summaries cannot supply check verdicts.
Only exact structural rules can carry that veto. Candidate-authored JSON,
keyword presence, and render-marker assertions remain noncritical judge inputs;
fixture-owned deterministic results are exposed anonymously to the judge but
cannot veto. Judge spend is reported separately from candidate spend. Pair
identity includes the probe ID, full-probe hash and authority, tier, starting
source, and both artifact hashes, but deliberately excludes the caller-selected
run ID. The separate causal pair ID
binds that artifact-pair identity to the exact run and both generation IDs.
Reports allow the same artifact-pair identity when distinct run IDs, generation
receipts, producer sessions, and telemetry prove independent causal attempts.
They reject duplicate run IDs and any reused generation ID, producer session,
raw telemetry, or generation receipt. Canonical presentation seeds come from
the generation-bound run row and a caller cannot substitute another seed. Each
judge sees only a disposable anonymous A/B workspace plus the same hash-checked
neutral starting-source tree under `INPUT`—not the fixture manifest, role map,
or opposite order. The prompt binds that source hash and requires factual and
quantitative candidate claims to be checked against it while candidate evidence
remains grounded in A/B paths.
Artifact trees cannot overlap or hard-link either role, evaluator metadata,
fixtures, identity manifests, harness checkouts, or comparison output.
`claim-check` accepts only sealed raw receipts and recomputes its report; an
aggregate JSON file is never an evidence input. Receipt paths are copied once
into a private bounded snapshot set before validation, and all report/claim
reads use those frozen bytes, so a concurrent path replacement cannot create a
validated/aggregated hybrid. It requires one coherent
canonical identity manifest across the campaign and independently recomputes
the current evaluator checkout's repository/commit/tree identity before a
release claim can pass.
Schema-v6 pair manifests are the first pair-identity format with evaluator-owned
causal generation, enforced artifact packages, physical arm separation, and
embedded sealed raw producer telemetry. They also carry the canonicalized full
probe snapshot, hash, and explicit canonical/custom authority. Schema-v7
receipts are the first portable outcome format that additionally retains,
rehashes, and reparses both
raw judge responses before independently re-deriving every winner, dimension,
evidence, warning, and scope-creep field. Schema-v6 and earlier receipts fail
closed; schema-v5 and earlier pair evidence also lacks the causal generation
authority above, even when an older integrity seal is otherwise coherent.
The canonical manifest seals the native user-local Claude Code install,
exact executable SHA-256, CLI version, pinned judge model, and exact digest of
the four-case expected-outcome calibration contract. `validate` checks and
binds that contract; it does not misrepresent the check as a live model run.
The same receipts
seal that policy, one coherent executable digest, requested and returned model
IDs, judge-schema hash, and per-order prompt hashes. Report and claim validation
regenerate both prompts from the embedded probe and require the exact current
bundled probe-ID/hash roster for canonical authority. PATH stubs, other CLI
releases, model aliases, custom/default-model judges, mixed judge identities,
missing path-grounded evidence, and blocking challenger warnings cannot satisfy
the release gate.

Candidate cost and exact token buckets are derived from canonical raw Claude CLI
JSON captured by the evaluator; whole-second wall time is measured around that
CLI process.
Both generation receipts, raw producer telemetry, and exact raw judge responses
are embedded in the portable pair receipt and revalidated by report/claim-check.
Release claims require canonical producer authority and fail closed on missing,
stale, duplicated, or custom generation evidence. These are local execution
receipts, not independent provider-billing attestations.

The SHA-256 seals are tamper-evident integrity checks inside the repository's
cooperative same-user trust boundary, not signatures from an external
authority. Likewise, identity binding proves what clean Git checkouts the local
evaluator inspected; it is not a remote execution attestation.
`campaign-init` prints a unique policy hash. Publishing that hash in an external
immutable channel before the first paid run is required before describing the
study as independently preregistered; the local campaign receipt alone proves
sealed first-attempt ordering only within this cooperative boundary.

## Campaign ledger

| Campaign | Manifest hash | Candidate source | Baseline source | Model(s) | Pairs | Outcome | Cost/wall receipt | Date |
|---|---|---|---|---|---:|---|---|---|
| First quality-loop campaign | — | — | `14680a955e1ae0e427dbfa641de13051b0cad47d` / `fcb391c3004368d15a264ff16b513733935e0f18` | — | 0 | **pending — evaluator implemented; no paid campaign has run** | — | — |

Passing this protocol is evidence of improvement on the sampled work, not a
mathematical guarantee of perfection or future-model behavior.
