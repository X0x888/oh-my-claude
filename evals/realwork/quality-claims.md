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

## Preregistered release threshold

A campaign may be called a positive receipt only when `pairwise.sh claim-check`
passes all of these fixed thresholds:

- every pair is bound by the canonical `harness-identities.json` campaign to
  the same exact pre-feature baseline commit/tree and the same exact clean
  release-candidate commit/tree; custom identity manifests are not release evidence
- the shipped six-probe portfolio is used without post-hoc substitutions, with
  at least 3 attempted pairs in every probe × (`balanced`, `economy`) stratum
- at least 30 conclusive independent artifact pairs across at least 6 domains and 2 model tiers
- challenger wins at least 60% and loses at most 20% of conclusive pairs
- the exact two-sided paired sign test (ties excluded) is positive with p <= 0.05
- no sampled domain has a negative challenger win-minus-loss margin
- at least 20 artifact pairs receive a valid five-axis judgment (hard-check vetoes are outcome evidence, not taste judgments)
- at least 4 of the 5 quality dimensions have positive signed margins
- the `visionary` win-minus-loss margin is at least 15 percentage points
- zero challenger critical-check failures
- zero challenger scope-creep judgments
- complete candidate cost and wall-ratio coverage for every conclusive pair
- median candidate cost and wall-time ratios are at most 1.75x
- p95 candidate cost and wall-time ratios are at most 2.5x

Order-swapped judge calls collapse to one artifact-pair observation. A position
disagreement is a tie, not two votes. Identical artifacts auto-tie. A critical
ground-truth failure computed from the shipped fixture's deterministic rules
vetoes a judge preference; candidate summaries cannot supply check verdicts.
Judge spend is reported separately from candidate spend. Pair identity is the
probe, tier, starting source, and both artifact hashes, so changing a random
presentation seed cannot replay the same work. Each judge sees
only a disposable anonymous A/B workspace—not the role map or opposite order.
`claim-check` accepts only sealed raw receipts and recomputes its report; an
aggregate JSON file is never an evidence input. It requires one coherent
canonical identity manifest across the campaign and independently recomputes
the current evaluator checkout's repository/commit/tree identity before a
release claim can pass.

The SHA-256 seals are tamper-evident integrity checks inside the repository's
cooperative same-user trust boundary, not signatures from an external
authority. Likewise, identity binding proves what clean Git checkouts the local
evaluator inspected; it is not a remote execution attestation. Candidate usage
economics are producer-reported, schema-checked, and frozen into the pair
manifest; the evaluator does not claim independent provider-billing attestation.

## Campaign ledger

| Campaign | Manifest hash | Candidate source | Baseline source | Model(s) | Pairs | Outcome | Cost/wall receipt | Date |
|---|---|---|---|---|---:|---|---|---|
| First quality-loop campaign | — | — | `14680a955e1ae0e427dbfa641de13051b0cad47d` / `fcb391c3004368d15a264ff16b513733935e0f18` | — | 0 | **pending — evaluator implemented; no paid campaign has run** | — | — |

Passing this protocol is evidence of improvement on the sampled work, not a
mathematical guarantee of perfection or future-model behavior.
