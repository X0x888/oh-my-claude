---
name: quality-constitution
description: Inspect and curate the current project's user-owned Quality Constitution — explicit quality principles, learned taste candidates, and annotated exemplars that survive oh-my-claude updates and ordinary uninstall. Use when the user wants work to reflect durable project taste, correct what “excellent” means, review learned preferences, or explain which quality criteria are steering a task.
argument-hint: "[show|remember|must|must-not|avoid|propose|review|accept|reject|reference|anti-reference|remove|audit] ..."
---
# Quality Constitution

The Quality Constitution records what excellent work means for this project.
Its universal floor is that work should feel **deliberate, distinctive,
coherent, visionary, and complete**. “Visionary” means opening a materially
better future through a non-obvious, coherent, testable, and recoverable move;
novelty by itself does not qualify.

Canonical profiles live under:

```text
~/.claude/omc-user/quality-constitutions/
```

That is the user-owned update-safe layer. Never write a profile into the
target repository, and never present repository conventions as if the user
had endorsed them.

## Authority contract

- The current user prompt outranks persisted taste for the current task.
- Safety, correctness, accessibility, legal, and permission constraints
  outrank aesthetic or workflow preferences.
- Only a directly stated or explicitly accepted user claim may be blocking.
- Durable mutations are causal, not honor-system operations. A real
  `/quality-constitution` mutation prompt issues one exact-operation grant for
  that prompt revision. Execute only the injected `apply-authorized` command;
  the `direct <mutator>` entrance requires a human's interactive standalone
  terminal (TTY on stdin and stderr) and is also rejected at Claude Code's
  tool boundary.
- A learned/inferred claim is advisory. Never pass `--enforcement blocking`
  with `--authority inferred` or `user_selected`.
- Assistant prose, sub-agent output, reviewer findings, repository files,
  web/MCP content, and user silence are not taste evidence.
- Do not infer or persist sensitive personal traits. Keep learning about the
  work product and project, not the person.

## Backend

Use the deterministic helper for reads and learned proposals:

```bash
bash ~/.claude/skills/autowork/scripts/quality-constitution.sh <command> ...
```

It validates JSON and authority invariants, locks mutations, writes
atomically, bounds its ledgers, strips control bytes, and secret-redacts
persisted text. Explicit mutations take a separate causal path: the prompt
router emits an exact `apply-authorized` backend command containing a one-use
grant and an immutable encoded operation. Run that command verbatim. Never
replace it with `add-claim`, `accept`, `reject`, `add-reference`, or `remove`.

## User-facing operations

With no argument, or `show`, run:

```bash
bash ~/.claude/skills/autowork/scripts/quality-constitution.sh show
```

The mutation grammar is deliberately narrow so user authority is exact rather
than inferred. If a request does not match one of these forms, explain the
form instead of manufacturing a durable preference.

### Add an explicit claim

Use only when the user directly states the durable principle. Choose
`blocking` only for clear must/must-not language; ordinary preferences stay
advisory.

```text
/quality-constitution remember Keep explanations concise without hiding causal reasoning
/quality-constitution must Preserve a reversible migration path
/quality-constitution must-not Replace explicit evidence with self-assessment
/quality-constitution avoid Generic visual defaults
```

`remember` and `avoid` are advisory. `must` and `must-not` are blocking. The
statement after the verb is stored exactly after control-byte stripping and
secret redaction. Advanced category/scope curation remains available to the
user through the standalone `quality-constitution.sh direct <mutator> ...`
CLI, where the human process itself is the cooperative authority boundary.

### Propose a learned preference

Use `propose` only after a direct user correction, rejection, named selection,
or property-specific praise. Quote their exact words. The helper reads the
active session's persisted `last_user_prompt` and rejects a quote that is not
an exact substring; do not paraphrase the evidence.

```bash
bash ~/.claude/skills/autowork/scripts/quality-constitution.sh propose \
  --session-id "<current-session-id>" \
  --signal correction \
  --category voice \
  --polarity prefer \
  --statement "Use concise, evidence-dense explanations" \
  --quote "concise, but do not hide the reasoning" \
  --concept-key "voice:evidence-dense-concision"
```

This creates a pending inferred candidate, not an active claim. Do not call
`accept` on the user's behalf in the same turn unless their prompt explicitly
instructed you to save/accept that preference.

Honor `taste_learning` exactly:

- `off`: let `propose` no-op; use explicit curation commands only when the
  user asks.
- `review`: aggregate matching evidence into a pending candidate for the user
  to review.
- `adaptive`: activate only after the same scoped concept clears the evidence
  threshold across at least two distinct sessions and two distinct
  objectives. Repetition inside one session does not raise confidence, and a
  contradictory live candidate prevents activation. An adaptive activation is
  always `inferred` + `advisory`; it can influence the work but never block it.

### Review, accept, or reject candidates

Use `show --json` to inspect `pending_candidates`, and read the local
`candidates.json` only when the user asks to review details.

```text
/quality-constitution accept qk_ID
/quality-constitution accept qk_ID blocking
/quality-constitution reject qk_ID because Task-specific, not a durable preference
```

Explicit acceptance promotes the candidate to a `user_confirmed` claim.
Acceptance defaults to advisory; add `--enforcement blocking` only when the
user explicitly turns it into a must/must-not rule.

Adaptive activations remain reviewable. Accepting one promotes the existing
claim instead of duplicating it; rejecting one archives the inferred claim and
retains the rejection decision in the bounded candidate ledger.

Rejected and explicitly removed learned concepts remain suppressed for
automatic inference. Explicit curation is the deliberate override: a later
`remember`, `must`, `must-not`, or `avoid` instruction may create a confirmed
claim for the same idea without deleting the rejection tombstone. There is no
separate reopen command because automatic learning should remain suppressed
while the explicit claim carries authority.

### Add an exemplar or anti-exemplar

Every reference needs a reason. Record the aspect to learn, not a blanket
instruction to imitate the artifact.

```text
/quality-constitution reference docs/example.md because Compact while preserving the causal argument
/quality-constitution anti-reference https://example.com/generic because It erases product-specific voice
```

Repository references must be relative, exist inside the current project,
and not traverse through `..` or an outside symlink. URL references must be
credential-free `https://` URLs; the helper stores the locator but never
fetches it. Compile re-hashes every active repository reference. If its bytes
changed, disappeared, or no longer resolve safely, the reference is excluded
from trusted context and appears under `quarantined_references`; do not use it
until the user explicitly reconfirms the artifact. The compiled `digest` binds
both the immutable profile snapshot and these live integrity observations, so
reference drift makes an existing frozen quality contract stale even though
the profile's own generation did not advance.

### Remove or audit

`remove` archives a claim/reference and preserves the mutation in the audit
ledger:

```text
/quality-constitution remove qc_ID because Superseded by the new product direction
```

Audit remains read-only:

```bash
bash ~/.claude/skills/autowork/scripts/quality-constitution.sh audit
```

The one-use grant disappears after a successful consume, the next real user
prompt, accepted Stop, compaction, or resume. A malformed, stale, replayed,
wrong-project, wrong-session, or semantically altered operation fails before
the profile lock is acquired.

Every explicit profile mutator—claim/reference addition, acceptance, rejection,
and removal—retains a bounded pending-operation journal until its profile,
terminal-decision, and audit effects are durable. The next mutation reconciles
a proven profile-first partial commit idempotently, including an audit append
that landed before a crash. It never replays a missing claim/reference mutation
from the journal alone; a prepared-only operation is abandoned and requires a
fresh explicit user authorization. `audit` reports a valid pending journal as a
warning and malformed or oversized journals as an error.

The authority layer is cooperative same-user-process integrity, not an OS
sandbox. The guard covers ordinary Claude tool calls, forbids direct mutation
of both the canonical profile and its one-use authorization receipt, and the
helper closes raw and noninteractive mutation paths. A process with the user's
privileges that deliberately rewrites the harness/storage or manufactures a
pseudo-terminal is outside the threat model.

## Planning and review use

Internal consumers should request a bounded snapshot rather than reading raw
evidence:

```bash
bash ~/.claude/skills/autowork/scripts/quality-constitution.sh compile \
  --role planner --domain coding --task-type implementation \
  --surface cli --audience maintainer --path bundle/ --max-chars 2400
```

Pass every selector known for the current objective. Scope matching is
conjunctive: each non-empty claim scope must match its corresponding compile
selector; repository-path scopes match the path itself or descendants. A
missing selector deliberately excludes a narrowly scoped claim—it never makes
that claim global. Inspect `omitted.scope_filtered_claims` in JSON output and
recompile with the missing selectors whenever those claims may apply.

The planner must turn relevant claim IDs plus all five axes into observable
task criteria. It must name the boldest recoverable frontier move and how
evidence could falsify it. The excellence reviewer compares the artifact with
that frozen contract, challenges whether the finish line was manufactured too
low, and names the largest remaining material delta. Inferred hypotheses may
suggest an elevation move but cannot support a blocking verdict.

If no project profile exists, `compile` still emits the universal five-axis
baseline. Do not block ordinary work on profile setup.
