# Definition of Excellent protocol

oh-my-claude's ordinary gates answer a necessary question: did the work receive
the expected planning, verification, and review? They cannot answer the harder
question by themselves: was the finish line ambitious and specific enough?

The Definition of Excellent protocol makes that finish line a causal artifact.
For qualifying `/ulw` work, the lifecycle is:

```text
objective -> frozen quality contract -> mutation -> current evidence
          -> blind frontier challenge -> remediation or clear frontier
          -> certified closeout
```

This is an enforcement protocol, not a claim that a language model can prove
perfection. It makes the quality bar explicit, preserves user taste across
sessions, prevents the implementer from silently weakening the bar after seeing
the work, and makes a stronger result testable against the previous harness.

## The five axes

Every armed contract must give task-specific, falsifiable treatment to all five
axes. Adjectives and generic best-practice lists do not satisfy the contract.

- **Deliberate** — material choices follow the objective, audience, constraints,
  evidence, and stated trade-offs rather than defaults or accidental convention.
- **Distinctive** — the result has a defensible point of view and is recognizably
  for this project and audience, rather than interchangeable generic output.
- **Coherent** — its parts reinforce one architecture, product logic, narrative,
  or interaction model; adjacent surfaces do not express conflicting standards.
- **Visionary** — it considers and, where defensible, realizes a credible
  step-change in the user's outcome. Novelty theatre, speculative expansion, and
  violating a frozen non-goal count against this axis.
- **Complete** — explicit scope, reasonably implied sibling scope, failure paths,
  integration, verification, documentation, and operational finish are
  reconciled.

Visionary is therefore neither a synonym for “more” nor permission to gold-plate.
A deliberately restrained implementation may be visionary when its higher-
leverage move is a simpler operating model, a reversible path, or a better
framing of the real problem.

## Arming policy

`definition_of_excellent=adaptive|always|off` is a user-authority setting.
Project configuration cannot weaken it.

- `adaptive` arms for medium/high-risk, broad or cross-domain work, open mandates,
  and explicit craft language such as *perfectionist*, *whole new level*,
  *distinctive*, *visionary*, *production quality*, or *complete*.
- `always` arms every material execution objective. Genuinely read-only
  advisory, checkpoint, and session-management turns remain inert.
- `off` is the explicit user escape. The Zero Steering policy promotes
  `adaptive` to `always` at runtime.

A qualifying fresh objective creates a new contract generation. A continuation
inherits the contract only while it preserves the objective; a scope-expanding
continuation must re-arm it. Advisory, checkpoint, and session-management turns
leave that in-flight contract and cycle untouched, but do not apply its Stop
gate to a genuinely read-only non-execution response. They are not mutation
labels: every recognized mutating tool still passes the frozen-contract
preflight, and an observed mutation stamps the exact prompt revision so Stop
promotes that turn into Definition certification. A later execution
continuation remains armed against the preserved bar. Existing sessions without
the tracking marker retain legacy behavior until their next fresh execution
objective.

## Frozen quality contract

The planner emits only the semantic payload on one `QUALITY_CONTRACT_JSON:` line.
The recorder validates it, injects causal metadata, and publishes it atomically
with `current_plan.md` as `quality_contract.json`.

```json
{
  "north_star": "observable outcome",
  "audience": "named audience",
  "stakes": "why quality matters here",
  "ambition_boundary": "highest defensible bar without violating constraints",
  "axes": {
    "deliberate": "task-specific bar",
    "distinctive": "task-specific bar",
    "coherent": "task-specific bar",
    "visionary": "credible step-change and how to test it",
    "complete": "task-specific bar"
  },
  "standards": [
    {
      "kind": "user|profile|repo|domain|external",
      "reference": "source of the standard (the exact compiled statement for profile)",
      "rationale": "why it applies",
      "profile_entry_id": "required only when kind is profile"
    }
  ],
  "anti_goals": ["specific thing the solution must not become"],
  "criteria": [
    {
      "id": "Q-001",
      "class": "must|aspiration",
      "axis": "deliberate|distinctive|coherent|visionary|complete",
      "claim": "observable, falsifiable result",
      "rationale": "why it matters",
      "surfaces": ["artifact or deliverable area"],
      "evidence_policy": {
        "allowed_kinds": ["test", "render", "benchmark", "inspection", "comparison", "source"],
        "minimum": 1,
        "requires_empirical": true,
        "requires_independent_review": true
      },
      "proof_method": "concrete way to decide",
      "proof_spec": {
        "receipt_kinds": ["exactly one of test|render|benchmark|inspection|comparison|source"],
        "tool_names": ["exactly one exact tool name or bounded mcp__...* prefix"],
        "command_contains": ["task-specific command token"],
        "artifact_contains": ["task-specific path, route, or target token"]
      },
      "failure_signal": "what would disprove the claim",
      "tradeoff_boundary": "constraint that limits this criterion"
    }
  ]
}
```

The harness adds the schema version, contract ID and digest, objective digest,
prompt timestamp/revision, review-cycle ID, enforcement generation, plan
revision, creation time, planner native identity, lifecycle dispatch identity,
and whether the contract was late. At the first mutation, the harness freezes an
immutable floor containing the contract's north star, audience, stakes,
ambition boundary, axes, standards, anti-goals, and criteria. A later revision
may raise that bar or add genuinely new scope, but cannot rewrite or remove any
frozen commitment. Every accepted revision invalidates prior proof. A new
objective starts a new contract generation; post-hoc deletion or weakening is
never allowed inside the current generation.

Every axis must appear in `axes` and have at least one mandatory criterion with
empirical proof and independent review. The first freeze needs five to ten
criteria and deliberately reserves ten more slots for additive scope revisions
(twenty total). Reaching that explicit revision ceiling fails closed and
requires a human rescope or new objective; a planner cannot hide a scope addition
in prose because the first contract consumed all structural capacity. Criteria
use unique stable IDs, distinct task-bound proof anchors and failure signals, a
non-empty anti-goal, and every active explicit blocking Constitution statement
is bound by exact ID and text. Bare wildcards, generic surfaces such as
`artifact`, and five renamed copies of one quality claim are rejected. A
mandatory visionary criterion must admit benchmark, render, or comparison
evidence; “make it innovative” is invalid.

Each criterion has `minimum: 1`, exactly one receipt kind, exactly one tool
pattern, and consumes exactly one receipt that matches exactly one frozen
`proof_spec`. When the finish line needs alternative or multiple independent
proofs, the planner creates separate criteria with distinct anchors. This avoids
both union-cover deadlocks and pretending shell aliases, wrappers, or path
spellings are a decidable semantic identity: a combined receipt that matches
multiple criteria certifies none.

The validator also proves that every frozen receipt language can intrinsically
reach the configured confidence threshold through the installed hooks: `Bash`
can mint test, benchmark, comparison, inspection, or executable-render receipts
without an artifact target; `Read` can mint source receipts; `Grep` can mint
inspection receipts; and recognized non-mutating MCP observations can mint
render or inspection receipts when their built-in score reaches that threshold.
Freeze-time MCP scoring assumes empty output and no contingent UI-edit history,
so a passive screenshot or DOM snapshot cannot become an impossible default-40
proof merely because an unrelated edit *might* later add confidence. A user may
deliberately configure a compatible lower threshold, but the planner cannot
assume incidental context. Silent Bash render commands likewise remain below
the bar; result-bearing authoritative render runs can cross it. Unknown tools,
impossible kind/tool pairs, and Bash-only artifact targets are rejected.
Mutation-capable browser operations
such as `browser_evaluate` and `browser_run_code` advance the edit clock and
never mint proof, even though legacy scoring can classify their output. For
`Bash`, the validator also sends a synthetic witness containing every frozen
command anchor through the production authoritative-execution parser and
receipt-kind derivation. Help/dry-run modes, compound shell grammar, and anchors
that force a different kind are rejected before the contract can freeze. The
same feasibility pass constructs conservative bounded superstrings: every
required command token must fit the persisted 500-character receipt command,
and every artifact token must fit the persisted target. Truncation can
therefore never make an accepted proof language unsatisfiable. `Read`/`Grep`
command and artifact anchors must fit one canonical `pwd -P` target including
the real project-root overhead; fragments such as `/../`, `/./`, and `//`
that canonicalization removes cannot become frozen proof obligations, and no
slash-delimited source-path component may exceed the portable 255-byte
filename ceiling. Every MCP proof must bind a non-generic route, path,
selector, URL, or target in `artifact_contains`; its full anchor language
must fit the recorder's 240-character descriptor-value cap. Tool-name-only
observations and descriptor keys such as `target=` are rejected.

Before the first recognized workspace mutation, PreToolUse recomputes contract
validity from the sidecar. Missing, malformed, stale, symlinked, wrong-objective,
wrong-cycle, wrong-plan, or wrong-enforcement artifacts fail closed and direct a
fresh `quality-planner` dispatch. Stop repeats the same validation, covering
write-capable connector tools whose mutation semantics are not knowable at
PreToolUse.

## Evidence and the frontier review

An accepted `excellence-reviewer` return carries one `QUALITY_REVIEW_JSON:`
envelope immediately before its dispatch ID and terminal verdict:

```json
{
  "criteria": [
    {
      "id": "Q-001",
      "status": "met|unmet",
      "evidence_kind": "test|render|benchmark|inspection|comparison|source",
      "basis": "artifact-grounded decision",
      "refs": ["vr-one-uniquely-matching-harness-receipt"]
    }
  ],
  "frontier": {
    "material": false,
    "bar_quality": "strong",
    "title": "largest remaining improvement, or why none dominates",
    "why": "expected user value and scope fit",
    "recommended_move": "bounded next experiment or shipped move",
    "criterion_ids": ["Q-004"],
    "evidence": ["vr-harness-minted-receipt-id"],
    "experiment": "how the claim was or can be falsified"
  },
  "alternatives_searched": ["credible alternative considered"],
  "limits": ["what this review could not establish"]
}
```

The reviewer must independently construct the strongest plausible improvement
before reading implementer self-ratings. It then checks the frozen contract and
current artifacts. A generic suggestion such as “add tests/docs/polish,” an
unsupported aesthetic preference, cost, elapsed time, implementation difficulty,
or “I cannot judge” when an empirical check was available cannot become a
material frontier finding or clear one.

Only the recorder may add causal fields. It validates the native binding,
objective, cycle, enforcement generation, plan revision, contract ID, and current
surface revision, then atomically publishes:

- one current evidence row per accepted criterion receipt in
  `quality_evidence.jsonl`;
- the latest `quality_frontier.json`;
- an append-only `quality_frontier_history.jsonl` row;
- the ordinary completeness verdict and state mirrors.

An additive contract revision makes prior assessments stale, but it does not
make an unresolved material frontier cease to exist. Before publishing such a
revision, the planner transaction requires the current open frontier and its
complete evidence pair to be regular, schema-valid artifacts and requires that
exact frontier to be the latest valid row in the bounded history ledger. Missing,
malformed, nonregular, or stale history refuses the revision and rolls contract,
evidence, frontier, history, plan state, and the causal planner call back to their
exact pre-attempt bytes. On success, a clear frontier (or no review yet) is
invalidated normally; an open frontier and its evidence remain as superseded,
non-certifying carryover until causally newer counterproof replaces them. Their
old contract and plan coordinates cannot tick the new gate, but they remain a
second authority source if history is later lost or corrupted. Receipt retention
protects the carried frontier's bounded proof portfolio independently of history.

This closes the user-visible failure mode where scope expansion could make a
real finding disappear and let Claude claim completion, eliminating the need for
the user to remember and reassert that finding. The steady-state cost is bounded
to validation of at most 64 frontier-history rows and retention of at most 20
receipt IDs; it adds no agent call and no token-bearing prompt. The end-to-end
regression injects missing, malformed, symlink, and interrupted-publication
history before re-contracting, proves byte-for-byte rollback, then deletes
history after a successful revision and proves same-proof clearing still fails
while valid newer proof can recover.

Historical rows are retained for audit but never tick a gate. Any relevant edit
or replan makes them stale. Every empirical result resolves to exactly one
harness-minted receipt bound to tool input, observed output digest, contract,
plan, objective cycle, and edit generation. Compound/help/dry-run Bash commands,
repeated normalized copies of the same proof identity, receipts matching more
than one criterion, and browser observations of the
wrong route or target cannot certify a criterion. A generic passing test cannot
prove design, taste, usability, or visionary value unless the frozen
`proof_spec` says exactly what that test decides.

Receipt outcome and criterion truth are deliberately separate for observational
proof. A successful `Read`, `Grep`, or observational MCP receipt says the
observation was available; the independent reviewer may honestly conclude
either `met` or `unmet` from what it observed. A failed observation establishes
neither, cannot support a fresh assessment, and cannot invalidate an older
reviewed assessment. A later successful observation may contain different
semantic facts, so causal ledger order makes the older assessment stale until
an independent reviewer interprets the newer uniquely matching receipt.
Assertion-bearing tests, benchmarks, comparisons, and Bash checks remain
strictly congruent: a passing assertion can support only `met`, and a failed
assertion only `unmet`. A newer failed assertion receipt that uniquely matches a
criterion invalidates an older certification until later successful proof is
independently reviewed.

A material frontier must produce `FINDINGS`; it blocks completion until the move
is implemented and the affected criteria are re-proven, or a later independent
review clears it with causally newer, distinct empirical counterevidence for
every affected criterion. Repeating the pre-finding receipt map cannot clear the
frontier. A frozen non-goal or external blocker may justify explicit rescoping,
and `/ulw-skip <reason>` / `definition_of_excellent=off` remain human-owned
escapes; reviewer prose alone is not a resolution. A clean verdict must prove
every `must` criterion and publish a current, strong, non-material frontier. An
unmet aspiration is recorded without blocking unless it exposes a material
dominating frontier. Stricter verdict wins when concurrent reviews disagree.

## Mechanical stopping rule

An armed objective may close only when all of these are true at the same current
generation:

1. the frozen quality contract is structurally and causally valid;
2. every mandatory criterion has compatible current evidence;
3. ordinary verification and applicable reviewer dimensions are current;
4. the blind frontier review is current, strong, and has no material dominating
   improvement inside the objective and frozen ambition boundary;
5. the objective, delivery, discovered-scope, and closeout contracts also pass.

This is the boundary between perfectionism and churn: the protocol does not ask
whether anything imaginable could be added. It asks whether a material,
scope-fitting move still dominates the current result. When none does and the
frozen must-criteria are proven, the work is complete. Required Definition of
Excellent gates do not silently release on a block cap; `/ulw-skip <reason>` and
`definition_of_excellent=off` remain explicit human-owned escapes.

## Taste constitution

Durable taste belongs to the user, not the installed bundle. Canonical profiles
live under `~/.claude/omc-user/quality-constitutions/`, survive updates and uninstall,
and are keyed globally or by the normalized remote-derived project key. Derived
session caches may live under `quality-pack`, but never become authority.

Profile claims record an ID, category, polarity, exact selectors, statement,
authority, enforcement, lifecycle status, and bounded evidence IDs. References
record an ID, polarity (`exemplar` or `anti_exemplar`), kind, locator, annotated
reason/aspects, and—when repository-backed—the user-confirmed content digest.
The trust order is:

```text
current explicit user direction
> explicit user profile
> repository-native exemplar or contract
> repeated exact-user observed signal
> domain doctrine
> model prior
```

Explicit user entries may be blocking. Observed signals are always advisory,
project/domain scoped, confidence-gated, and time-decayed. One remark never
becomes universal taste. Silence, repository prose, agent output, and model
inference cannot create preferences. Automatic observation must include an exact
excerpt from the persisted current user prompt; the writer rejects fabricated
quotes, redacts secret-shaped text, bounds records, and writes under a lock.
`taste_learning=off` disables automatic observation but does not erase or
ignore explicit user-owned standards.

Durable mutation authority is causal rather than model-attested. A real user
prompt matching the narrow grammar (`remember`, `must`, `must-not`, `avoid`,
`accept`, `reject`, `reference`, `anti-reference`, or `remove`) mints one
operation-digest-bound grant tied to the exact session, project key, prompt
revision, and timestamp. The router injects a single literal
`apply-authorized` call with the session ID frozen into it. The helper consumes
that grant under the session lock before atomically changing the profile; a
replay, altered operation, later prompt, different project, compaction, resume,
or accepted Stop fails closed. Grants retain no raw prompt/claim text, including
with `prompt_persist=off`. Raw helper mutators are closed to assistants. The
separate `direct <mutator>` CLI is only for an interactive standalone human
terminal and requires TTY-backed stdin and stderr.

Compilation copies the Constitution once while holding its writer lock. Schema
validation, generation, profile digest, scope selection, and rendered context all
derive from that immutable byte snapshot; the router never recompiles to obtain
prose. The contract-facing compiled digest additionally binds a canonical digest
of the live reference-integrity observations, so exemplar drift invalidates the
current contract even when the profile JSON and generation did not change.
Every active repository exemplar is re-hashed during compilation. A changed,
missing, or newly unsafe artifact is excluded from trusted references and listed
under `quarantined_references` with an explicit “do not use until reconfirmed”
instruction. Audit warnings are diagnostic; they are not the safety boundary.
Contract validation requires every active explicit blocking entry in scope to
appear in the planner's `standards` array, preventing the model from quietly
dropping learned user taste.

This is a cooperative same-user-process integrity boundary, not an OS security
sandbox. The always-on PreTool guard denies raw/compound/split helper calls,
direct mutation of canonical storage or the one-use authorization receipt, and
write-capable or unclassified MCP operations that target either surface; it
pins observer binaries before parsing hook input.
The helper independently closes raw and noninteractive mutation paths. A process
with the user's filesystem privileges that deliberately manufactures a
pseudo-terminal or rewrites the harness/storage can still tamper with the data;
filesystem isolation and authentication are outside this Bash harness's threat
model.

## Continuity, status, and closeout

Compaction and resume handoffs carry a bounded capsule: contract ID/revision,
five-axis summary, criteria met/required, missing proof, frontier state, and
paths for the contract, immutable pre-mutation floor, verification receipts,
evidence, and frontier. State without its authoritative sidecar fails closed.

`/ulw-status` reports arming reason, contract validity, axis coverage, proof
count, weakest unmet criterion, frontier state, late-contract status, and active
versus candidate taste entries. Closeout fingerprints include the contract,
immutable floor, receipt ledger, evidence, and frontier digests, so a
post-review mutation or proof-ledger change invalidates READY. Closeout prose
names the Definition of Excellent and its weakest tested axis; self-description
never substitutes for artifacts.

Typed gate events use the release-visible `definition-of-excellent` namespace:
the root records arming, while `/plan`, `/contract`, `/verification`,
`/authority`, `/pre-mutation`, `/reviewer-dispatch`, `/review`, `/frontier`,
and `/stop` identify the producing stage. The `/frontier` stream distinguishes
clear reviews, first material discovery, repeated confirmation, and remediation;
`/ulw-report` renders the exact stage/event taxonomy rather than collapsing
non-blocking lifecycle events into the generic block table.

Reports derive material-frontier discovery and remediation counts/rates from
the bounded authoritative `quality_frontier_history.jsonl` episodes preserved
in session summaries, not from best-effort event counts. Episodes follow the
ordered objective review cycle, so a clear review after an additive,
floor-preserving re-contract remediates an open frontier from the superseded
contract instead of leaving a false unresolved snapshot. Missing history stays
`unavailable`, malformed rows are disclosed and excluded, and zero-denominator
rates render as `n/a`. This sits alongside latency and tokens: a frontier
reviewer that never finds a worthwhile delta is ceremonial, while one that
always finds one is manufacturing churn.

## Proving improvement over the previous harness

Mechanism tests prove causal integrity; they cannot prove taste. Release claims
therefore use blind artifact-level A/B evaluation against the exact pre-feature
harness. Candidates receive identical
fixtures and prompts. Fixture-owned mechanical checks veto broken-but-flashy results,
then an isolated judge evaluates deliberate, distinctive, coherent, visionary,
and complete twice with candidate order reversed. Order disagreement collapses
to a tie.

“Exact pre-feature harness” is an evaluator-owned identity contract, not a
producer label. The canonical `evals/realwork/harness-identities.json` pins the
baseline's repository slug, commit, and tree. Its boundary is the committed
repository state immediately before this feature was implemented, retaining
unrelated improvements already present at task start; a machine's older
installed SHA is deployment state and is deliberately not the comparator. The
manifest also identifies feature surfaces that must be absent from the baseline
and present in the challenger. `pairwise.sh compare` requires
separate clean baseline and challenger Git checkouts, proves the baseline is
that exact commit/tree, proves the challenger is a distinct descendant at the
current evaluator checkout with all required feature surfaces, and derives
both identity hashes itself. Producer summaries must echo the corresponding
role and derived hash but cannot choose them. The manifest snapshot and both
exact identities are frozen into every schema-v3 receipt; the default claim
gate rejects missing, mixed, custom, stale, or current-checkout-mismatched
campaign identities.

The campaign preregisters rubric and source hashes, model IDs, sample size,
quality thresholds, scope-creep limits, and cost/latency ceilings. A quality-loop
release requires at least 30 independent artifact pairs across six domains and
two model tiers; non-inferior hard-check performance; at least 60% wins and at
most 20% losses among conclusive pairs; a positive significant paired sign test;
visionary wins exceeding losses by at least 15 percentage points; no negative
domain; and bounded cost and wall-time ratios. The gate recomputes those results
from sealed raw pair receipts; caller-authored aggregate reports are not claim
evidence. Calibration cases remain evaluator-development tooling, not a claim
that a campaign's judge has received an independent calibration attestation.
The local hash seals and checkout binding are tamper-evident evidence within the
same-user cooperative trust boundary, not a signed remote-execution
attestation.

Until such a receipt exists, the honest claim is that the harness has a stronger,
auditable quality mechanism. After it exists, “better than the previous harness”
is a falsifiable result rather than another assertion made by the harness about
itself.
