# Claims ledger — mechanism receipts

Every substantial harness mechanism carries a **receipt**: a measured,
counterfactual delta from `arms.sh` probe runs. A mechanism whose receipt
shows a null delta on the current model tier is a trim candidate; a
mechanism with a large delta is load-bearing and stays. This ledger is the
subtraction criterion the v1 post-mortem named as structurally missing
("addition was cheap; subtraction was impossible-by-construction").

## Governance (non-negotiable)

- **Will-contracts are not trimmed on receipts alone.** The no-defer /
  no-out-of-scope / goal-gate machinery stays untouched regardless of probe
  outcomes unless the owner explicitly signs off after seeing the data.
- **Trims land only on a null-delta receipt** — measured, not argued — and
  each trim ships with the probe rerun that would detect regression.
- A probe result is model-tier-scoped. A trim cleared on one tier is NOT
  cleared for weaker tiers; the `model` column is part of the receipt.

## How to produce a receipt

```sh
# one-time headless auth (sandboxed arms never inherit interactive login):
claude setup-token && export CLAUDE_CODE_OAUTH_TOKEN=...

bash evals/realwork/arms.sh doctor
bash evals/realwork/arms.sh campaign --probe no-defer-contract --runs 10
bash evals/realwork/arms.sh report --probe no-defer-contract --claims
```

Paste the emitted row below, newest first, with date and model.

## Ledger

| Mechanism | Probe | Delta (receipt) | Runs | Model | Date | Verdict |
|---|---|---|---|---|---|---|
| No-defer will-contract (`core.md` contracts + stop-guard) | `no-defer-contract` | **unmeasured — instrument ready** | 0 | — | 2026-07-04 | pending first campaign |
| Anti-shallow-thinking scaffold (`intellectual-craft.md` + `model-robustness.md`) | `depth-scaffold` | **unmeasured — instrument ready** | 0 | — | 2026-07-04 | pending first campaign |
| Always-on doctrine chain cost (~15.8k tokens/session measured) | `cost-cache` | **unmeasured — instrument ready** | 0 | — | 2026-07-04 | pending first campaign |

## Reading a receipt

- `no-defer-contract`: the load-bearing column is `flag_fully_removed`
  (full vs bare). Large gap → will-contract earns its weight. Null gap →
  the single most consequential trim finding possible; escalate to owner.
- `depth-scaffold`: the load-bearing column is `hidden_consumer_fixed`
  (full vs trimmed-scaffold). Null gap on a strong model → the ~5.5k-word
  scaffold half is a belt-trim candidate (pointer-form, contracts intact).
- `cost-cache`: pure cost axis. Small deltas → doctrine weight is
  cache-amortized and criterion-6 work should target hook process overhead
  instead; large deltas → the chain itself is the latency surface.
