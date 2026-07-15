---
name: council
description: Adaptive project evaluation that maps the task's actual risks, assembles the smallest useful specialist team, and fills material coverage gaps before synthesis.
argument-hint: "[optional focus or project path] [--deep] [--polish] [--self-audit]"
disable-model-invocation: true
---
# Project Council

Evaluate this project with a task-specific team. Start from the risks and unanswered questions in the actual project, not from a standing committee of job titles.

$ARGUMENTS

## Argument flags

- `--deep` — Escalate Sonnet-backed specialists to `model: opus` for deeper reasoning. Shipped-inherit deliberators keep parameter omission and ride the current session model; never hard-code a temporary/current-session model name. Explicit user/env `model_overrides` still win; project-conf overrides are ignored. Use when the project is high-stakes, the user explicitly asked for a thorough audit, or a previous shallow pass missed something. Cost is meaningfully higher; reserve it for cases where depth is the bottleneck. Detection: if `$ARGUMENTS` contains `--deep` as a whitespace-separated standalone token (e.g. `/council security --deep`, including at the end of the args), set DEEP_MODE for the rest of this protocol. Variants like `--deep=true`, `-deep`, or `-d` are NOT recognized — use the bare `--deep` flag.

- `--polish` — Raise taste/excellence coverage in the risk map and extend the relevant mandates with a Jobs-grade rubric. `visual-craft-lens`, `product-lens`, and `design-lens` become strong **candidates**, not a forced roster; include only the ones that answer a material question, and do not suppress a concrete security, reliability, data, or architecture risk merely because the project is mature. Relevant specialists receive: **soul** (single-hand vs. kit-assembled feel), **signature** (one recognizable visual/interaction), **voice** (copy + tone consistency without AI-isms across empty states / errors / settings / onboarding), **negative space** (chrome defers to content), **first-five-minutes** (new-user wow moment), **AI-as-experience** (product feature vs. wrapped API), and the **no-cloning discipline** (≥3 things done differently from the closest archetype). **Auto-activates on polish-saturated projects**; explicit `/council --polish` works on any project. Composes with `--deep`. Detection mirrors `--deep`: bare `--polish` token in `$ARGUMENTS`, or auto-activation when the project-maturity prior emits `polish-saturated`.

- `--self-audit` — Self-evaluation mode for oh-my-claude itself. The Bug B post-mortem (v1.34.x) identified "self-exemption from our own tools" as a structural failure. Seed the coverage map with contract shape, producer/consumer alignment, recovery/lifecycle behavior, classifier boundaries, observability, and test realism. `abstraction-critic`, `oracle`, `sre-lens`, and `quality-researcher` are strong candidates for those questions, not a mandatory quartet; select or skip each with evidence and add a different specialist when the inspected surface demands it. Phase 8 is advisory by default; the user re-runs with explicit implementation intent if findings warrant action. Detection mirrors `--deep`: bare `--self-audit` token in `$ARGUMENTS`. Auto-activates if `$PWD` is the oh-my-claude repo root AND the user's prompt explicitly mentions "harness" / "state-io" / "implicit contract" / "self-audit" / "Bug B"-class language. Composes with `--deep`. Run quarterly; cadence captured in `CONTRIBUTING.md`. Read-only — surfaces findings, does not edit.

**Automatic explicit-uncertainty mode:** if the actual request names a tricky, uncertain, intermittent/flaky/non-deterministic or sporadic problem; hard/difficult reproduction; an unknown/not-known root cause; conflicting evidence; or architectural uncertainty, set both `UNCERTAINTY_MODE` and `DEEP_MODE` even when the user did not know to pass `--deep`. Resolved or explicitly negated wording does not activate this rule unless a separate positive signal remains. Generic breadth, severity, or a large/high-risk project does not activate it either. The primary selection must include at least one best-fit role whose shipped declaration is `inherit` (normally `oracle` for unknown root cause, `quality-planner` for uncertain execution shape, `metis` for a fragile premise, or the relevant inherit reviewer). Follow the authoritative resolver for that Agent call—normally omit `model`, but an explicit user/env override still wins. Selected Sonnet-backed roles receive the normal deep escalation. This spends strong reasoning once before weaker retries multiply, without naming or pinning the current session model.

## Agentic protocol (load-bearing — re-read after any compaction)

Before any dispatch, anchor on these rules so they survive context pressure:

1. **Ground every finding in evidence.** A finding without a file path, line number, or concrete observed behavior is opinion, not output. If a specialist skipped citations, name the gap in the synthesis instead of repeating the unsupported claim.
2. **Do not synthesize on partial returns.** If any dispatched specialist has not returned, report what is in flight and continue waiting. Synthesis on a partial set silently biases the assessment toward whichever specialist responded fastest.
3. **Verify the top of the stack before presenting.** Up to three load-bearing findings drive the user's actions. Re-verify each against the actual code before it ships in the assessment (Step 6). Unsupported specialist claims are noise, not signal.
4. **Preserve tensions, do not synthesize them.** When two specialists contradict, verify the factual premise and surface any genuine value tradeoff. A clean synthesis that hides real disagreement is worse than no synthesis.
5. **The five-priority rule governs presentation, not execution scope.** A project with 47 findings needs 5 priorities at the top of the assessment, not 47 equal-weight items. If the synthesis emerges with more than 5 critical findings, you have under-prioritized the *headline* — pick the top 5 by impact x reach. **However**, when `is_exhaustive_authorization_request()` matches, all findings flow into the Phase 8 wave plan; the five-priority rank only determines wave ordering. Do not silently clip scope to 5.

## Protocol

### 1. Inspect

Read the project's README, manifest files (package.json, Cargo.toml, pyproject.toml, Podfile, etc.), entry points, and directory structure. Determine:

- **Project type**: web app, API/backend, CLI tool, library/SDK, mobile app, desktop app, browser extension, infrastructure/DevOps, documentation site, monorepo (mixed)
- **Maturity**: greenfield, MVP/prototype, production, mature/legacy
- **Tech stack**: languages, frameworks, databases, external services
- **User-facing?**: does this have end users, or is it developer tooling / infrastructure?

### 2. Build the coverage map

Map **questions and risks before agents**. The council is the temporary team assembled from this map; the named agents are reusable capabilities, not mandatory seats.

For each plausible dimension, record: `(a)` concrete applicability evidence from Step 1, `(b)` impact if missed, `(c)` competence needed, and `(d)` `selected`, `covered-inline`, or `skipped` with a reason. Consider all of these, but never dispatch merely to fill the table:

| Coverage need | Strong candidate capabilities (examples, not an allowlist) |
|---|---|
| User value, journey, prioritization | `product-lens` |
| UX, accessibility, interaction | `design-lens` |
| Visual craft, signature, polish | `visual-craft-lens`, `design-reviewer` |
| Security, privacy, trust boundaries | `security-lens` |
| Data model, instrumentation, evidence quality | `data-lens`, `rigor-reviewer` |
| Reliability, performance, deployment, operations | `sre-lens` |
| Architecture, abstraction, contract shape | `abstraction-critic`, `oracle` |
| Correctness, tests, edge cases | `quality-reviewer`, `metis` |
| External APIs, current standards, source truth | `librarian`, `quality-researcher` |
| Research/citation/methodological rigor | `literature-scout`, `rigor-reviewer` |
| Prose, messaging, traceability | `editor-critic`, `briefing-analyst` |
| Adoption/distribution | `growth-lens` |
| Task-specific expertise not named above | the best matching installed/custom inspection agent, or a `general-purpose` agent with a narrow read-only mandate |

Inspect the available Agent roster and descriptions; do not restrict selection to `*-lens` names. Prefer inspection/judgment agents for the assessment. A builder may participate only when it is the sole source of needed domain competence, and its prompt must say the assessment round is read-only—implementation belongs to Phase 8.

Select the **smallest primary set that jointly covers every material high-risk row**: normally 1–4 specialists. One is valid for a narrow, specialist question. Exceed four only when the evidence map contains more than four mutually independent, high-impact competence needs that cannot be combined safely; name that exception and its cost in the selection ledger. There is no minimum-three rule, no hard four-seat ceiling, no product/security fallback, and no reward for panel size. Give every selected specialist one non-overlapping question and explicit non-goals. Before dispatch, show a compact selection ledger: selected specialist → assigned coverage → why; plausible-but-skipped specialist/family → why not applicable.

When `UNCERTAINTY_MODE` is active, the smallest sufficient set still contains one appropriate role whose shipped declaration is `inherit`. This is a reasoning-path requirement, not permission to add a generic standing seat: choose the role that can resolve the named uncertainty, route it through the authoritative resolver (normally omission; explicit user/env override wins), wait for it, and integrate its evidence before any fixed-model Phase-8 implementer starts.

Persist that ledger before dispatch with `record-council-coverage.sh init` (JSON on stdin). Use `coverage_rows[] = {id, need, evidence, impact, competence, status: selected|covered-inline|skipped, reason}` and `selections[] = {agent, phase: primary|gap-fill, coverage_ids, reason, non_goals}`. `init` accepts one or more primary selections and **zero gap-fill selections**; the normal primary envelope is one to four. When the evidence truly requires more than four, also provide `primary_exception = {reason, cost, independent_high_impact_coverage_ids}` whose IDs exactly cover the exceptional primary mandates. Selected coverage IDs may appear under only one mandate. Agent identity is exact when namespaced; an unnamespaced installed-agent name may bind once to its runtime identity, but cannot authorize two namespaces that share a short name. The Agent PreTool hook rejects `[council:primary]`/`[council:gap-fill]` dispatches that are absent from this objective-scoped lifecycle, so the coverage map and include/skip reasoning are auditable rather than presentation-only. A later Council prompt in the same session may call `init` again: the writer recognizes the new prompt revision, archives the prior map to bounded history, and starts clean; same-prompt concurrent/duplicate initialization is serialized and exactly one succeeds.

`--polish` raises the product/UX/visual/voice rows as priors; it does not force those agents or suppress evidenced engineering risks. `--self-audit` seeds the harness-specific rows described above; its four named candidates remain optional based on the inspected surface.

### 3. Primary dispatch

Launch the selected primary specialists concurrently using the Agent tool in one message. Each call should include:

- A description beginning exactly with `[council:primary]` so the dispatch is recorded as Council evidence without relying on the agent's name
- The project path, type, maturity, stack, and the evidence that made this coverage row material
- One precise question and explicit non-goals so mandates do not overlap
- The instruction: "Evaluate this assigned risk only. Ground every finding in concrete code or observed behavior. End with what remains outside your competence or evidence. This assessment round is read-only."
- For every selected agent: "Before any unsuccessful universal `VERDICT:` token, emit one unindented non-empty `FINDINGS_JSON: [...]` line. Each object must contain actionable `severity`, `category`, `file`, `line`, `claim`, `evidence`, and `recommended_fix` fields." Clean/successful returns need no finding payload. This keeps every role vocabulary auditable without enabling arbitrary-prose scraping.

Before the primary dispatch, assess `MODEL_RISK` once from the coverage map and set it to exactly `low`, `medium`, or `high`:

- `low` — bounded, well-understood, reversible work with stable evidence.
- `medium` — the default when the assessment needs material judgment or the evidence does not clearly justify either extreme.
- `high` — explicit uncertainty/unknown cause, unstable or conflicting evidence, hard reproduction, or safety-critical/irreversible consequences. `UNCERTAINTY_MODE` always sets `MODEL_RISK=high`.

Project breadth alone does not imply `high`. `DEEP_MODE` still passes the helper's `--deep` flag independently, so an explicit/deep quality request lifts eligible specialists even when the ordinary risk assessment is lower. Resolve the complete selected set once with the authoritative helper (one call, not one call per agent). In the template, initialize `MODEL_RISK=medium` and replace it with the assessed `low` or `high` literal when the criteria require:

```bash
MODEL_RISK=medium
bash ~/.claude/skills/autowork/scripts/resolve-agent-model.sh --context council --risk "${MODEL_RISK}" --json agent-one agent-two
```

Replace the example names with the selected identities and add the helper's `--deep` flag only when Council DEEP_MODE is active. If the current `/ulw` turn already includes a `SUBAGENT MODEL ROUTING` directive, use that equivalent decision without paying for the helper call. Follow every returned route exactly: `action=pass` means pass `tool_model`; `action=omit` means omit the Agent `model` parameter. Explicit user/env overrides have highest precedence; project-conf overrides are ignored. Normal balanced Council leaves shipped Sonnet-backed lenses on Sonnet; `--deep` raises those selected specialists to Opus. Shipped-inherit deliberators omit the parameter and ride the current session model. Unknown/custom agents without an explicit override also omit the parameter and keep their own definition.

**If DEEP_MODE is active** (explicit `--deep`, configured deep default, or automatic explicit-uncertainty mode), also add: "This is a deep-mode evaluation. Take more turns to investigate suspicious findings. Read source carefully rather than inferring from directory shape. Report uncertainty explicitly."

The primary assessment stays on the Agent tool, not the background Workflow tool: reconciliation needs the actual returns in context. The Workflow tool's place is Phase 8 heavy execution.

### 4. Wait, reconcile, and gap-fill

Do not reconcile a round until **every specialist in that round** has returned. Status updates may name what remains in flight, but do not present a partial assessment.

After the primary round, reconcile every return against the coverage map. Mark each selected row `evidenced`, `partial`, `uncovered`, or `newly-discovered`. Pay special attention to each specialist's "cannot assess" section and to contradictions between specialists.

Run **one gap-fill round of 0–2 specialists** only when:

- a high-impact row remains partial or uncovered;
- a return exposes a new material risk outside the primary team's competence; or
- a cross-perspective conflict needs a different competence to resolve the factual premise.

Select gap-fill agents from the full roster by the same rules (including the unsuccessful-verdict structured-output requirement), give them only the missing question, prefix every Agent description with `[council:gap-fill]`, dispatch them concurrently, and wait for every gap-fill return. If none is warranted, say why; do not manufacture a second round.

Persist reconciliation with `record-council-coverage.sh update` even when no gap-fill is needed. Include:

- `reconciliation.status`: `primary-complete` when no second round is needed, otherwise `gap-fill-required`;
- `reconciliation.evidence`: a concrete cross-return summary;
- `reconciliation.primary_returns`: the exact ledger identities of every returned primary;
- `reconciliation.gap_fill_returns`: empty at this stage; and
- `reconciliation.coverage_results[] = {coverage_id, status, evidence, reason}` for every selected row.

Only that post-primary generation may add gap-fill selections, and there may be at most two total. `primary-complete` is valid only when every selected result is `evidenced`; any partial, uncovered, or newly discovered result must take the sole gap-fill path. Every gap-fill coverage ID must point to such an unresolved result. After every gap-fill returns, call `update` again with status `gap-fill-complete`, exact returns, final results, and explicit residual limitations.

### 5. Synthesize

After all required rounds return:

1. **Deduplicate** — Combine the same issue found from different angles without hiding the contributing perspectives.
2. **Rank by impact** — Score severity × breadth × urgency.
3. **Preserve tensions** — Separate factual disagreement from legitimate value tradeoffs; never smooth either away.
4. **Separate quick wins from strategic work.**
5. **Reject unsupported findings.** A claim without concrete evidence is either dropped or labeled as an unresolved coverage gap.
6. **Report residual limitations.** A deliberate skip is honest scope; an unnamed omission is a workflow defect.
7. **Mark user-decision findings narrowly (v1.40.0 contract — LOAD-BEARING, do NOT soften).** Under `no_defer_mode=on` (default), the criterion is operational only: credentials/login, an external account action, or a destructive shared-state action awaiting confirmation. Taste, policy, brand voice, pricing, data-retention defaults, release attribution, library choice, refactor scope, and credible-approach splits are agent decisions. If `no_defer_mode=off`, the older broader pause behavior applies. Do not widen the default criterion.

### 6. Verify top findings

Group related load-bearing claims by domain and shared evidence, then verify each group with the **best independent competence**, never automatically with `oracle` and never with a finding's original author. One verifier may receive up to three tightly related claims in a single mandate; unrelated domains remain separate. Normal mode uses zero or one verifier dispatch unless conflict, uncertainty, or severity justifies another. Deep/high-risk work may use up to three dispatches:

- security/privacy claim → a different security-capable reviewer;
- scientific/statistical claim → `rigor-reviewer`;
- external API/current-standard claim → `librarian`;
- correctness/test claim → `quality-reviewer`;
- architecture/cross-cutting claim → `oracle` or `abstraction-critic`, whichever did not originate it;
- UX/accessibility claim → `design-lens` or `design-reviewer`, whichever is independent.

Each verifier receives the exact claims and cited evidence, then: "**Try to REFUTE each claim** against the actual source. Treat each as a possible false positive until evidence forces otherwise. Report holds / partially holds / does not hold per claim, defaulting to does not hold when evidence is thin."

Prefix every verifier Agent description with `[council:verification]` so this independent round remains distinguishable from primary coverage. The runtime accepts it only against the current final-reconciled, not-yet-completed ledger, stamps objective/generation provenance, rejects repeated exact verifier identities, and enforces the three-dispatch cap. Zero verifiers remains valid.

Use the return to confirm, refine, demote, or drop each finding. Skip verification already made mechanically conclusive by direct reproduction. The three-dispatch runtime cap remains a ceiling, not a target; batching same-domain claims prevents verification from becoming a second council.

### 7. Present

Deliver the unified assessment in this format:

```
## Project Council Assessment

### Project Profile
- **Type**: [web app / API / CLI / library / etc.]
- **Maturity**: [greenfield / MVP / production / mature]
- **Stack**: [key technologies]

### Coverage and Selection
- **Consulted**: [specialist → assigned coverage, split by primary / gap-fill / verification]
- **Deliberate skips**: [plausible perspective → concrete reason it was not applicable]
- **Residual limitations**: [unresolved evidence or competence gaps]

### Critical Findings (address first)
[Findings with high severity — security vulnerabilities, data loss risks, broken core flows]
Each finding: what it is, which specialist found it, why it matters, concrete fix.
Mark verification status: ✓ verified (Step 6), ◑ refined, or ✗ demoted/dropped during verification.

### High-Impact Improvements
[Findings that significantly improve the product but aren't emergencies]
Each finding: what it is, which specialist found it, expected impact, effort estimate (quick win / moderate / strategic)

### Strategic Recommendations
[Longer-term improvements for competitive advantage]
Each: what to build, which specialist identified the need, why it matters for the product's future

### Cross-Perspective Tensions
[Where specialists disagree — e.g., "growth wants faster onboarding, security wants stronger auth"]
Present the tension honestly and let the user decide

### Quick Wins
[Things that can be done in a day or less with meaningful impact]
Bulleted, actionable, specific

### What's Working Well
[Genuine strengths worth preserving — brief, not a praise section]
```

Once every selected round and any optional verifier have returned, reconciliation is final, independent checks are incorporated, and this unified assessment is ready to present, run `record-council-coverage.sh complete`. This is the only operation that arms the two-turn “implement the assessment” handoff. It refuses an in-flight or unreconciled Council and records objective provenance.

### 8. Execute (when implementation was requested)

Step 7 ends with a presentation. Council ends there only if the user asked for advisory output ("just analyze", "report only", "advisory only"). If the user's prompt asked for implementation/fixes (any **Phase 8 entry marker** — see canonical list below), bridge from assessment to execution with this protocol — do not stop after Step 7.

**Phase 8 entry markers** (these phrases request implementation and therefore enter Phase 8; they do **not** all authorize an unexpectedly expanded finding set):

- *Imperative scope:* `implement all`, `implement`, `fix all`, `fix everything`, `ship`, `ship it all`, `ship them all`, `address each one`, `address all`, `every item`, `every finding`, `every gap`, `every wave`, `cover all`, `complete all`, `tackle all`
- *Continuation scope:* `do all` (waves|gaps|findings|of them|of it), `continue all` (gaps|findings|waves|of them)
- *Quality bar:* `make X impeccable`, `make X perfect`, `make X world-class`, `make X production-ready`, `make X polished`, `make X enterprise-grade`, `make X excellent`, `make X flawless`
- *Binary-quality framing:* `0 or 1`, `either 0 or 1`, `middle states are 0`, `no middle ground`
- *Catch-alls only when paired with mutation:* `exhaustively fix`, `thoroughly implement`, or equivalent. An exhaustive/thorough **assessment** remains advisory.

**Exhaustive authorization is a stricter, separate contract.** `is_exhaustive_authorization_request()` in `lib/classifier.sh` is authoritative. It recognizes explicit all/every/everything forms, exhaustive language attached to implementation/remediation, high-bar `make X impeccable`-class targets, and binary-quality framing. Thorough assessment wording alone is intensity, not scope authorization; an explicit top-N or selected/severity subset wins over earlier broad adjectives. Bare `implement` or `ship` enters Phase 8 but does not, by itself, authorize every newly discovered finding. The prompt router emits `EXHAUSTIVE AUTHORIZATION DETECTED` only when that predicate succeeds.

1. **Build the master finding list.** Collect every finding from Steps 5/6 with stable IDs (`F-001`, `F-002`, …), severity (critical/high/medium/low), surface area (e.g., `auth/login`, `checkout/payment`, `cli/error-output`), and a rough effort estimate (S/M/L). The five-priority rule clipped the *headline* — execution restores the full set. Persist via `record-finding-list.sh` (writes `<session>/findings.json`); the master list is the source of truth for completion tracking.

2. **Group into waves.** Cluster findings by surface area or dependency, not arbitrary chunks. A wave should be coherent (one feature, one screen, one subsystem) so a single per-wave commit makes sense. Aim for 5–10 findings per wave. Order waves by criticality first, then by dependency (don't fix a UI surface in wave 1 that depends on a backend fix in wave 3).

3. **Surface the wave plan, create one evidence packet, and build one master implementation graph.** Show wave count, per-wave surface area, per-wave finding IDs, and total effort. In the active session directory write `council_evidence_packet.md` containing only: objective, authorized finding IDs, changed-file list + diff statistics, concise verification outcomes, risk factors, and links/paths to full logs. Refresh it when the diff generation changes and pass its path to every planner, implementer, and reviewer; agents should not independently rediscover the same repository facts or paste full logs into prompts. Dispatch `quality-planner` once for the complete authorized wave set: dependencies, per-wave implementation slices, verification contracts, commit boundaries, and rollback points. Persist that graph in the active plan and reuse its wave slices; re-plan only when newly discovered scope changes dependencies, a verification failure disproves an assumption, or session risk escalates. Do not pay for a fresh planner merely because the wave index advanced. If `is_exhaustive_authorization_request()` matches the prompt, proceed without confirmation. Otherwise apply the *Scope explosion without pre-authorization* pause case from `core.md` — surface the plan and ask whether to address top N, all N, or a different scope. Entering Phase 8 and authorizing scope expansion are deliberately different decisions.

   **Wave grouping is a structural constraint, not advice.** Aim for 5–10 findings per wave by surface area. If your plan emerges with avg <3 findings per wave on a master list of ≥5 findings, that is over-segmentation — merge adjacent surfaces until each wave is substantive. Single-finding waves are acceptable only when (a) the master list itself has <5 findings, or (b) one finding is critical enough to own its own wave (rare — name the reason in the wave commit body). The harness records wave shape via `record-finding-list.sh assign-wave` and a wave-shape advisory fires on under-segmented plans (see `record-finding-list.sh assign-wave` warnings and the wave-shape gate in `stop-guard.sh`).

   *Numerics are load-bearing across three sites:* the `5–10 findings per wave` target and `<3` floor in this paragraph, the `is_wave_plan_under_segmented()` predicate in `bundle/dot-claude/skills/autowork/scripts/common.sh` (`total < 3 * waves` AND `total ≥ 5` AND `waves ≥ 2`), and the user-facing block reason in `stop-guard.sh`'s wave-shape gate. If you change one, change all three in the same commit — the predicate and the gate copy must agree, and the canonical text here is what the model reads first.

4. **Execute waves sequentially — full cycle per wave.** For each wave N of M:

    *Substrate note: when `workflow_substrate=on` and the plan has at least 3 waves or projects at least 10 specialist/reviewer dispatches, use Claude Code's **Workflow tool** as a `pipeline()` — one item per wave, carrying the master graph, a shared token budget, deterministic outputs, and resume state. Below that threshold, hand-sequenced dispatch avoids engine overhead. The per-wave steps are identical either way — and reviewer verdicts remain inputs to challenge against evidence, not auto-accepts.*
    1. Load this wave's slice from the master implementation graph. Re-dispatch `quality-planner` only when the invalidation conditions in step 3 fired; record the changed assumption so re-planning is causal rather than habitual.
    1a. **Surface OPERATIONAL-BLOCKER findings only before executing (v1.40.0).** If the wave contains a finding with `requires_user_decision: true` AND the decision_reason names a real operational block (credentials, missing login, external account, a destructive shared-state action awaiting confirmation), present that finding's summary + decision_reason to the user before continuing into implementation. Under `no_defer_mode=on` (default), do NOT pause on findings marked user-decision for technical-judgment reasons (taste, policy, brand voice, library choice, credible-approach split) — those are the agent's call. Pick the sibling-of-codebase choice with stated reasoning in the wave plan, then ship; the user can redirect on review. If the field's `decision_reason` is ambiguous between operational and technical, default to autonomous execution and surface the choice in the wave commit body for the user to audit. The pause-on-user-decision behavior matches v1.39 only when `no_defer_mode=off`.
    2. Implement using the appropriate domain specialist agent(s).
    3. Assemble the complete review batch **before** dispatch. It always includes `quality-reviewer` on the wave diff. Add `excellence-reviewer` only when the adaptive route requires completeness (broad/open objective, current complex plan, unknown Bash scope, or qualifying cross-surface work); in that case give quality-reviewer `REVIEW MODE: defects-only`. Revisit the coverage map now and add every semantic risk specialist already selected for this wave (for example security, reliability, data integrity, architecture, design, or research rigor). Select the best matching competence from the full roster, give it the exact risk, and do not substitute a standing panel or run unrelated specialists "for breadth." The runtime review-coverage gate enforces canonical changed-surface dimensions only—it does not choose semantic lenses for you. Any non-standard/custom specialist should emit `FINDINGS_JSON` so its findings enter discovered-scope enforcement deterministically. When the prompt mentioned "impeccable", "enterprise grade", "polished", or similar, extend the excellence-reviewer mandate with the concrete enterprise-polish rubric: error, empty, and loading states; copy tone; accessibility; edge cases; motion; and relevant dark-mode/RTL/responsive behavior. Prefix **every** Agent description in this settled batch with the exact machine marker `[review-batch]` (place it immediately after any required `[council:*]` prefix). `record-pending-agent.sh` converts that marker into one deterministic objective+revision batch ID; do not mark implementation or later unrelated calls.
    4. Freeze the settled wave revision and launch quality, conditional excellence, and **all already-selected semantic risk specialists in the same concurrent frozen-revision batch**. Wait for every marked role to return. The mutation guard keeps the revision frozen until the last matching pending row settles, including when quality returns before a slower semantic specialist. Reconcile the whole batch exactly once, then make one remediation pass; do not edit while only part of the paid evidence has returned.
    5. Reserve any later semantic-specialist dispatch for **genuinely new evidence or an invalidated risk-map premise** discovered after that batch. Name the trigger. Ordinary remediation does not justify replaying the same semantic review; prove the fix with the wave's verification and run only the affected gate re-review that current edit freshness requires.
    6. Run the strongest meaningful verification for the wave's domain.
    7. Commit with title `Wave N/M: <surface> (F-xxx, F-yyy, ...)` and a body listing each finding ID and what changed.
    8. Update each finding's status in `findings.json` (✓ shipped / ⚠ deferred / ✗ rejected) with commit SHA and any notes.
    9. **If a wave reveals a new finding** (review uncovered something the council missed, or implementation surfaced an adjacent defect that meets the Serendipity Rule), append it to the master list with `record-finding-list.sh add-finding <<< '{"id":"F-NNN","summary":"...","severity":"...","surface":"..."}'` and either fold it into the current wave (if same surface, bounded fix) or assign it to a new follow-on wave with `assign-wave`. Do NOT silently fix it without recording — that breaks the per-finding traceability the protocol exists to provide.

5. **Final summary after all waves.** Present:
    - Master finding-list table: every ID → status with commit SHA or deferral reason.
    - Aggregate verification results across waves.
    - Cross-wave concerns surfaced (regressions, conflicts, follow-ups).
    - The `Serendipity:` line for any adjacent fixes per `core.md` rules.

**Resuming a Phase 8 session.** If a session compacts or crashes mid-wave, `findings.json` survives on disk. On resume, do NOT call `record-finding-list.sh init` again — that refuses by default but `--force` would clobber the wave plan and lose every shipped/commit-tracked finding. Instead: run `record-finding-list.sh counts` and `show` to see where execution stands, identify the in-progress wave (`status="in_progress"`), and re-enter at step 4 of that wave. Findings already marked `shipped` are done; pending findings in the in-progress wave still need work.

**Phase 8 is skipped** when the user said "advisory only", "just analyze", "don't act yet", "report only", or similar — in those cases, end at Step 7's presentation.

**Anti-patterns Phase 8 exists to prevent:**
- **Single-shot mega-implementation** — 30 findings in one giant diff; reviewer chokes, real defects slip through.
- **Five-priority clipping** — "council headline said top 5, I'll only ship those" misreads the rank as scope. The rank is for presentation; execution covers the scope the user authorized in step 3. Cover every finding only when the exhaustive-authorization predicate succeeds or the user chooses all findings at the scope pause.
- **Cross-session handoff after wave 1** — "I'll do wave 2 next session" violates the segmentation rule in `core.md`. Waves are in-session structure, not cross-session phasing.
- **One mega-commit with no per-finding traceability** — kills bisectability, code review, and rollback.
- **Re-init clobbering on resume** — calling `init` on an already-populated wave plan and losing progress. Use `counts` first; `init --force` only when actually starting over.
- **Silent discover-during-execution** — fixing a newly-surfaced defect without recording it in the master list. If it qualifies under Serendipity, it qualifies for an `add-finding` entry too.

## Execution style

- **Challenge the project, don't praise it.** The value is in what's missing or wrong. Strengths get a brief mention, not a celebration.
- **Be specific.** "Improve error handling" is useless. "The /api/users endpoint returns a 500 with a stack trace when the email field is missing — return a 400 with a clear message" is useful.
- **When specialists disagree, present the tension.** Resolve factual premises through independent verification; preserve genuine value tradeoffs for the user.
- **Ground everything in evidence.** Every finding should reference a file, flow, or concrete observation.
- **Prioritize ruthlessly.** A project with 47 findings needs 5 priorities, not 47 equal-weight items.
