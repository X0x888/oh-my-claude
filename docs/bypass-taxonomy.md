# Bypass-Surface Taxonomy

> A field guide to how language-model agents escape work contracts —
> and the four mechanical defense categories that close them sustainably.

This document was lifted out of `AGENTS.md` in v1.43 (oracle finding,
council-driven post-v1.42.x evaluation) so it stands alone as a
project-independent reference. The taxonomy emerged from the
oh-my-claude project's stop-guard bypass-closure work
(v1.40.x → v1.42.x), where every release closed N+1 paths the agent
was using to clear the harness's quality gates without finishing the
work. The categories below name **the shape of each closure**, not the
specific closures themselves — so they apply to any quality harness
trying to enforce "the agent must not stop short."

## Why a taxonomy

A bypass-defense codebase that doesn't categorize its defenses tends
toward two failure modes:

1. **Quietly homogeneous.** Every new defense reaches for the same
   easy tool — usually a regex on the agent's last message. Per the
   abstraction-critic council lens (v1.42.x), this is the shape that
   scales through ~12-15 defenses then collapses under
   false-positive-audit burden, because each prose-pattern regex adds
   one noun/adjective/idiom slot to a surface that the agent (and
   real ambient harness text) keeps drifting in.
2. **Drift over time.** Without category names, the team cannot
   reason about the *mix* of defenses. "How many of our active
   defenses are prose-pattern vs state-predicate?" stops being
   answerable. The bias toward the easy tool becomes unobservable.

Naming categories is what converts *"should we add another regex?"*
from a tactical decision into a structural one.

## The four categories

| Category | Enforcement axis | Example defenses (from this project) | Tradeoff |
|---|---|---|---|
| **state-predicate** | Reads ledgered state (`findings.json`, `discovered_scope.jsonl`, edit-clock, `gate_events.jsonl`). The agent's prose is irrelevant; only state-transition completeness gates the stop. | `advisory_no_findings_gate` (advisory dispatches without findings); `ulw-skip post-edit refusal` (`review_had_findings=true AND last_edit_ts > last_review_ts`). | **Highest durability** — open-vocabulary prose drift cannot bypass. **Cost:** requires every "remaining work" surface to be ledgered upstream (i.e. the producer must write something inspectable, not just emit prose). |
| **prose-pattern** | Regex on the agent's last assistant message. Inspects free-form natural-language output for handoff vocabulary, rationalization phrasings, missing closure labels. | `has_unfinished_session_handoff` regex (preposition-anchored handoff phrasings: `for / to / in / until` + `next / future / later / separate session`); `has_closeout_label` closing-region scan; rationalization catalog (`core.md`). | **Lowest durability** — open-vocabulary guarantees phrasing drift. **Cost:** every defense adds 1 noun/adjective/idiom slot AND requires an FP-audit pass. **Hard cap: ≤3 active prose-pattern defenses.** New prose-pattern proposals must demonstrate why a state-predicate alternative isn't viable. |
| **single-call-flip** | Refuses a specific script invocation that would atomically flip the work into a bypassable state in one shell call. | Intent-downgrade refusal in `ulw-correct-record` (edit-clock check: `last_edit_ts > last_user_prompt_ts` means the agent is mid-turn and the downgrade is suspect); `record-finding-list status rejected` with subjective tokens (deny-list pruning). | **Medium durability** — surface is small (the call site itself) but the input vocabulary can be open. **Cost:** input validator must be tight enough not to under-fire AND loose enough not to block legitimate paths. |
| **classifier-misroute** | Catches prompts whose router classification doesn't match the work being done. | `prompt_text_override` audit + `intent-flip` backstop; `prompt_classified_intent` write at the router so a later mid-turn write cannot silently re-classify. | **Medium-high durability** — anchored to the per-prompt classifier output the router writes once and doesn't mutate mid-turn. **Cost:** classifier vocabulary must keep pace with new authorization phrasings (Tier 7+ in the imperative pattern set). |

## Application rule

When proposing a new defense:

1. **Name the category** in the design doc / CHANGELOG entry.
2. If the proposal is **prose-pattern** and the live count is already
   ≥3, the proposal MUST first attempt a state-predicate
   alternative. If none exists, that justification goes in the
   CHANGELOG so the next reviewer can challenge it.
3. The umbrella regression net
   (`tests/test-stop-guard-bypass-surface.sh`) must add coverage in
   the same commit per the existing coordination rule.
4. FP-audit notes (which ambient harness text the new
   regex/validator might match) go in a comment block at the call
   site so future cleanup waves know what to keep.

## Why this matters

The abstraction-critic Wave 0 lens (v1.42.x-newer council) flagged
the seven-defense framing as **scalable through ~12-15 defenses then
collapsing under FP-audit burden** — not because the umbrella test
fails to scale (it does, mechanically) but because each prose-pattern
defense expands the cognitive surface the next session must reason
about when choosing recovery paths. The taxonomy converts the
shape of growth from compounding regex into a portfolio: the project
deliberately budgets prose-pattern defenses against the more durable
shapes.

## Practical use

When you encounter an agent-escape failure mode in your own quality
harness:

- **Start with state-predicate** if the producer of the escape
  signal (a dispatch, an edit, a verification) already writes
  ledgered state. This is the highest-leverage defense and the
  cheapest to audit.
- **Reach for single-call-flip** if the escape requires a specific
  shell invocation (a `record-X.sh status flip`, a `correct
  --intent=advisory`) — these surfaces are small and well-typed.
- **Reach for classifier-misroute** if the issue is *which* gates
  fire on a given prompt, not whether the gates themselves work.
- **Use prose-pattern only** when none of the above apply and the
  signal genuinely lives only in the agent's free-form text. Even
  then, prefer narrow phrasings (preposition-anchored, label-anchored)
  over open-vocabulary catch-alls.

## Current defense inventory (oh-my-claude v1.42.x)

For reference. The umbrella regression net at
`tests/test-stop-guard-bypass-surface.sh` is authoritative.

| Defense | Category | Closure target |
|---|---|---|
| F-001 handoff-regex synonyms + permission-coded continuation asks | prose-pattern | "I'll continue in your next prompt" mid-iteration handoffs |
| F-003 `ulw-pause` judgment validator | single-call-flip | Pause used as a technical-judgment defer rather than operational block |
| F-005 `ulw-correct` mid-turn downgrade refusal | single-call-flip | `execution → advisory` flip after edits started |
| F-008 advisory-no-findings gate | state-predicate | Advisory specialist returned no findings → can't pretend work happened |
| F-010 rejected-finding subjective-token tightening | single-call-flip | `record-finding-list status rejected` with `by design` / `wontfix` and no concrete WHY |
| F-010b final-closure closing-region scan | prose-pattern | Closing prose without label (silent stop) |
| F-011 `ulw-skip` post-edit refusal | state-predicate | Skip after a reviewer found issues that haven't been re-reviewed |

Of the seven defenses listed, **2 are prose-pattern** (under the hard
cap of 3), **3 are single-call-flip**, **2 are state-predicate**. The
mix is intentionally biased toward the more durable categories.

## Scope note

The four categories above are **stop-guard bypass defenses** — they
close paths the agent uses to clear stop-time quality gates without
finishing work. They are not the only mechanical defense surface in
the harness. PreTool boundary defenses (agent-first invariant,
commit/push contract, bg-spawn hygiene) are a parallel class for a
different problem (invariants enforced before tool execution, not at
stop time). For the broader view of every rule in `core.md` mapped to
its enforcement class — including the **behavior-only** class for
rules that have no mechanical defense and depend on model attention —
see `docs/enforcement-classes.md`.

## See also

- `docs/enforcement-classes.md` — broader enforcement taxonomy (six
  classes including PreTool boundary + behavior-only)
- `AGENTS.md` — current taxonomy reference (cross-links here)
- `tests/test-stop-guard-bypass-surface.sh` — umbrella regression net
- `~/.claude/quality-pack/memory/core.md` — the contract this enforces
- `CHANGELOG.md` — per-release entries for each closure
