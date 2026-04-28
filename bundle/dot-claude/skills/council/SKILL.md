---
name: council
description: Multi-role project evaluation that dispatches expert perspectives (PM, design, security, data, SRE, growth) to surface blind spots and unknown unknowns a solo developer would miss.
argument-hint: "[optional focus or project path] [--deep]"
disable-model-invocation: true
model: opus
---
# Project Council

Evaluate this project from multiple professional perspectives to surface blind spots, unknown unknowns, and cross-cutting concerns that no single role would catch alone.

$ARGUMENTS

## Argument flags

- `--deep` — Escalate all dispatched lenses to `model: opus` for deeper reasoning. Default is the lenses' built-in `model: sonnet`. Use when the project is high-stakes, the user explicitly asked for a thorough audit, or a previous shallow pass missed something. Cost is meaningfully higher (each lens runs on opus instead of sonnet); reserve for cases where depth is the bottleneck. Detection: if `$ARGUMENTS` contains `--deep` as a whitespace-separated standalone token (e.g. `/council security --deep`, including at the end of the args), set DEEP_MODE for the rest of this protocol. Variants like `--deep=true`, `-deep`, or `-d` are NOT recognized — use the bare `--deep` flag.

- `--polish` — Narrow the lens roster to taste/excellence concerns and extend dispatch with a Jobs-grade evaluation rubric. Default lens roster becomes `visual-craft-lens` + `product-lens` + `design-lens`; security/data/sre/growth lenses are skipped unless the user named them explicitly — those audits are the wrong tool for a polish-saturated project that has already passed them. Each dispatched lens runs on opus and receives an extension prompt covering: **soul** (single-hand vs. kit-assembled feel), **signature** (one recognizable visual/interaction), **voice** (copy + tone consistency without AI-isms across empty states / errors / settings / onboarding), **negative space** (chrome defers to content), **first-five-minutes** (new-user wow moment), **AI-as-experience** (product feature vs. wrapped API), and the **no-cloning discipline** (≥3 things done differently from the closest archetype). **Auto-activates on polish-saturated projects** (per the project-maturity prior — long-running repos with deep tests and cross-session memory) so a `/council` invocation on a polish-saturated codebase gets the right lens automatically; explicit `/council --polish` invocation works the same on any project. Composes with `--deep` (both flags can apply). Use when the project has already passed engineering pragmatism gates and the next-leverage move is taste, signature, and excellence-bar work. Detection mirrors `--deep`: bare `--polish` token in `$ARGUMENTS`, or auto-activation when the project-maturity prior emits `polish-saturated`.

## Agentic protocol (load-bearing — re-read after any compaction)

Before any dispatch, anchor on these rules so they survive context pressure:

1. **Ground every finding in evidence.** A finding without a file path, line number, or concrete observed behavior is opinion, not output. Lens agents are instructed to do this; if a returned lens skipped citations, name the gap in the synthesis instead of repeating the unsupported claim.
2. **Do not synthesize on partial returns.** If any dispatched lens has not returned, report what is in flight and continue waiting. Synthesis on a partial set silently biases the final assessment toward whichever lens responded fastest.
3. **Verify the top of the stack before presenting.** The top 2-3 findings drive the user's actions. Re-verify each one against the actual code before they ship in the final assessment (Step 6 below). Surface-level lens claims that fail verification are noise, not signal.
4. **Preserve tensions, do not synthesize them.** When two lenses contradict, surface both in the "Cross-Perspective Tensions" section. A clean synthesis that hides a real disagreement is worse than no synthesis.
5. **The five-priority rule governs presentation, not execution scope.** A project with 47 findings needs 5 priorities at the top of the assessment, not 47 equal-weight items. If the synthesis emerges with more than 5 critical findings, you have under-prioritized the *headline* — pick the top 5 by impact x reach. **However**, when the user requests exhaustive implementation (canonical exhaustive-authorization vocabulary — see *Phase 8 entry markers* below), all findings flow into the Phase 8 wave plan; the five-priority rank only determines wave ordering. Do not silently clip scope to 5 — clipping is the failure mode this rule's most-common misreading produces.

## Protocol

### 1. Inspect

Read the project's README, manifest files (package.json, Cargo.toml, pyproject.toml, Podfile, etc.), entry points, and directory structure. Determine:

- **Project type**: web app, API/backend, CLI tool, library/SDK, mobile app, desktop app, browser extension, infrastructure/DevOps, documentation site, monorepo (mixed)
- **Maturity**: greenfield, MVP/prototype, production, mature/legacy
- **Tech stack**: languages, frameworks, databases, external services
- **User-facing?**: does this have end users, or is it developer tooling / infrastructure?

### 2. Select lenses

Choose 3-6 relevant role-lenses based on what you discovered. Use this guide:

| Lens | When to include | When to skip |
|------|----------------|--------------|
| `product-lens` | Any user-facing software, developer tools with adoption goals | Pure infrastructure, internal scripts |
| `design-lens` | Web apps, mobile apps, desktop apps, CLIs with interactive UX (UX flow / IA / onboarding / accessibility / error states) | Libraries, APIs, backend services, infrastructure |
| `visual-craft-lens` | Projects with a visible UI surface where visual design quality matters — landing pages, dashboards, native iOS/macOS apps, polished CLIs/TUIs (palette intent, typography hierarchy, depth/elevation, visual signature, generic-AI-pattern detection, archetype anti-cloning) | Pure backend/API/infra without a UI surface; internal tools where visual polish is non-goal |
| `security-lens` | Anything with auth, user data, external APIs, network exposure | Static sites with no data, read-only tools |
| `data-lens` | Products needing analytics, data-driven decisions, ML features | Early prototypes, pure infrastructure, CLI utilities |
| `sre-lens` | Production services, APIs, infrastructure, anything that runs 24/7 | Client-only apps, libraries, documentation |
| `growth-lens` | Consumer products, SaaS, marketplaces, open-source with adoption goals | Internal tools, infrastructure, scripts |

**Minimum 3 lenses, maximum 7.** If fewer than 3 are relevant, include product-lens and security-lens by default — they apply to almost everything. **`design-lens` and `visual-craft-lens` are disjoint by design** (UX flow vs. visual craft) — dispatch both for projects where both surfaces matter; they will not duplicate findings.

### 3. Dispatch

Launch ALL selected lenses in parallel using the Agent tool in a single message. Each agent call should include:

- The project path and what you learned about its type/stack in step 1
- A brief description of what the project does (from README or your inspection)
- The instruction: "Evaluate this project from your perspective. Ground every finding in concrete evidence from the codebase."

**If `--deep` was passed**, add the `model: "opus"` parameter to each Agent call to escalate the lens model. Also extend the per-lens instruction with: "This is a deep-mode evaluation. Take more turns to investigate suspicious findings. Read source files carefully rather than relying on directory structure inference. Report uncertainty explicitly when evidence is thin." This does not change the lens's `maxTurns` (that is set in the agent frontmatter and is not overridable from the dispatch), but the opus model uses its turns more effectively.

**Critical**: dispatch ALL lenses in ONE message so they run concurrently.

### 4. Wait

Do NOT begin synthesis until ALL dispatched lenses have returned their results. While waiting:
- Acknowledge which lenses are still running
- Share any early findings that are immediately actionable

### 5. Synthesize

After all lenses return, synthesize their findings:

1. **Deduplicate** — Multiple lenses may flag the same issue from different angles. Combine them.
2. **Rank by impact** — Score each finding by: severity (how bad if ignored) x breadth (how many users/scenarios affected) x urgency (time-sensitive or not).
3. **Attribute perspectives** — Note which lens surfaced each finding. Cross-perspective findings (flagged by 2+ lenses) get priority.
4. **Separate quick wins from strategic work** — Some findings are afternoon fixes; others are multi-week initiatives.
5. **Reject lens findings that lack evidence.** If a lens flagged "X is a problem" with no file/line/behavior citation, you cannot cleanly include it. Either drop it or name it as "lens raised this concern but did not cite evidence — needs separate investigation."
6. **Mark user-decision findings.** When a finding involves taste, policy, brand voice, pricing, data-retention, release attribution, or a credible-approach split (two reasonable paths where choosing wrong costs significant rework), tag it with `requires_user_decision: true` and a one-line `decision_reason` explaining what the user needs to weigh in on. The criterion mirrors `core.md`'s pause cases: pricing, brand voice, data-retention policy, release-note attribution, and any decision only the user can make. These findings are surfaced separately in Phase 8's wave executor — the executor pauses on them rather than choosing autonomously, so the marking is load-bearing for handoff. Backwards compatible: omitting the field defaults to `false`.

### 6. Verify top findings

Before presenting the final assessment, the top 2-3 highest-impact findings drive the user's most consequential actions. Surface-level lens output is not enough on findings that are load-bearing. Verify each one with a focused dispatch:

1. **Pick the top 2-3 findings** by `impact_x_reach`. Skip anything that is already obviously verified by clear file/line citations the lens provided. Skip anything where the user said "advisory only — don't act."
2. **Dispatch `oracle` per finding** (or, if all top findings are in one domain like security, dispatch the relevant lens once more with a deepening prompt — but `oracle` is the default because it is opus-grade and not bound to a single perspective). Each dispatch must include:
   - The exact claim, copy-pasted from the lens output.
   - The evidence the lens cited (file paths, lines, observed behavior).
   - The instruction: "Verify this claim against the actual code. Report whether it holds, partially holds, or does not hold. Cite specific files/lines. Note any caveats or context the original lens missed."
3. **Use the verification output** to either:
   - **Confirm** the finding (most cases): keep it as-is in the final assessment, optionally adding the verification's caveats.
   - **Refine** it: the underlying issue is real but the lens framing was off — restate using the verifier's framing.
   - **Demote or drop** it: the verifier could not reproduce the issue, the cited code does not behave as the lens claimed, or the issue is contingent on a context that does not apply.
4. **Cap verification at 3 findings.** More than that and you are running a second council, not verifying. If the top is a tie at 4+, pick the 3 with the most actionable ship-decisions riding on them.

This phase noticeably increases the trust the user can place in the final 2-3 findings — the ones they will actually act on — without growing the runtime by an order of magnitude.

### 7. Present

Deliver the unified assessment in this format:

```
## Project Council Assessment

### Project Profile
- **Type**: [web app / API / CLI / library / etc.]
- **Maturity**: [greenfield / MVP / production / mature]
- **Stack**: [key technologies]
- **Lenses consulted**: [list of lenses dispatched]

### Critical Findings (address first)
[Findings with high severity — security vulnerabilities, data loss risks, broken core flows]
Each finding: what it is, which lens found it, why it matters, concrete fix.
Mark verification status: ✓ verified (Step 6), ◑ refined, or ✗ demoted/dropped during verification.

### High-Impact Improvements
[Findings that significantly improve the product but aren't emergencies]
Each finding: what it is, which lens found it, expected impact, effort estimate (quick win / moderate / strategic)

### Strategic Recommendations
[Longer-term improvements for competitive advantage]
Each: what to build, which lens identified the need, why it matters for the product's future

### Cross-Perspective Tensions
[Where lenses disagree — e.g., "growth wants faster onboarding, security wants stronger auth"]
Present the tension honestly and let the user decide

### Quick Wins
[Things that can be done in a day or less with meaningful impact]
Bulleted, actionable, specific

### What's Working Well
[Genuine strengths worth preserving — brief, not a praise section]
```

### 8. Execute (when implementation was requested)

Step 7 ends with a presentation. Council ends there only if the user asked for advisory output ("just analyze", "report only", "advisory only"). If the user's prompt asked for implementation/fixes (any **Phase 8 entry marker** — see canonical list below), bridge from assessment to execution with this protocol — do not stop after Step 7.

**Phase 8 entry markers** (single source of truth — these phrases enter Phase 8 AND grant exhaustive authorization, so the wave executor proceeds without re-asking):

- *Imperative scope:* `implement all`, `implement`, `fix all`, `fix everything`, `ship`, `ship it all`, `ship them all`, `address each one`, `address all`, `every item`, `every finding`, `every gap`, `every wave`, `cover all`, `complete all`, `tackle all`
- *Continuation scope:* `do all` (waves|gaps|findings|of them|of it), `continue all` (gaps|findings|waves|of them)
- *Quality bar:* `make X impeccable`, `make X perfect`, `make X world-class`, `make X production-ready`, `make X polished`, `make X enterprise-grade`, `make X excellent`, `make X flawless`
- *Binary-quality framing:* `0 or 1`, `either 0 or 1`, `middle states are 0`, `no middle ground`
- *Catch-alls:* `exhaustive`, `exhaustively`, `thorough`, `thoroughly`

A bash predicate that mirrors this list — `is_exhaustive_authorization_request()` in `lib/classifier.sh` — is wired into the prompt-intent-router so the model receives an explicit "EXHAUSTIVE AUTHORIZATION DETECTED" directive when any of these phrases is present.

1. **Build the master finding list.** Collect every finding from Steps 5/6 with stable IDs (`F-001`, `F-002`, …), severity (critical/high/medium/low), surface area (e.g., `auth/login`, `checkout/payment`, `cli/error-output`), and a rough effort estimate (S/M/L). The five-priority rule clipped the *headline* — execution restores the full set. Persist via `record-finding-list.sh` (writes `<session>/findings.json`); the master list is the source of truth for completion tracking.

2. **Group into waves.** Cluster findings by surface area or dependency, not arbitrary chunks. A wave should be coherent (one feature, one screen, one subsystem) so a single per-wave commit makes sense. Aim for 5–10 findings per wave. Order waves by criticality first, then by dependency (don't fix a UI surface in wave 1 that depends on a backend fix in wave 3).

3. **Surface the wave plan.** Show wave count, per-wave surface area, per-wave finding IDs, and total effort. If the prompt explicitly authorized exhaustive implementation (any **Phase 8 entry marker** above — single source of truth at the top of Step 8), proceed without confirmation. Otherwise apply the *Scope explosion without pre-authorization* pause case from `core.md` — surface the plan and ask whether to address top N, all N, or a different scope.

   **Wave grouping is a structural constraint, not advice.** Aim for 5–10 findings per wave by surface area. If your plan emerges with avg <3 findings per wave on a master list of ≥5 findings, that is over-segmentation — merge adjacent surfaces until each wave is substantive. Single-finding waves are acceptable only when (a) the master list itself has <5 findings, or (b) one finding is critical enough to own its own wave (rare — name the reason in the wave commit body). The harness records wave shape via `record-finding-list.sh assign-wave` and a wave-shape advisory fires on under-segmented plans (see `record-finding-list.sh assign-wave` warnings and the wave-shape gate in `stop-guard.sh`).

   *Numerics are load-bearing across three sites:* the `5–10 findings per wave` target and `<3` floor in this paragraph, the `is_wave_plan_under_segmented()` predicate in `bundle/dot-claude/skills/autowork/scripts/common.sh` (`total < 3 * waves` AND `total ≥ 5` AND `waves ≥ 2`), and the user-facing block reason in `stop-guard.sh`'s wave-shape gate. If you change one, change all three in the same commit — the predicate and the gate copy must agree, and the canonical text here is what the model reads first.

4. **Execute waves sequentially — full cycle per wave.** For each wave N of M:
    1. Dispatch `quality-planner` for the wave's findings (decision-complete plan for the wave's scope only — not the whole project).
    1a. **Surface USER-DECISION findings before executing.** If the wave contains a finding with `requires_user_decision: true`, present that finding's summary + decision_reason to the user before continuing into implementation. Do NOT choose autonomously on user-decision findings — pausing on them is the rule's purpose, mirroring `core.md`'s pause cases (taste / policy / credible-approach split). Resume the wave once the user has weighed in. If the user defers ("you decide" / "use your judgment"), record the resolved direction in the finding's `notes` field for the audit trail.
    2. Implement using the appropriate domain specialist agent(s).
    3. Dispatch `quality-reviewer` on the wave's diff (small enough for real per-line signal — this is the upside of waves over single-shot).
    4. Dispatch `excellence-reviewer` for the wave's surface area. When the prompt mentioned "impeccable", "enterprise grade", "polished", or similar, extend the dispatch prompt with an explicit enterprise-polish checklist for the reviewer to evaluate against: error states (network failures, validation failures, server errors), empty states (no data, first-run, search-no-results), loading states (skeletons, spinners, optimistic UI), copywriting (tone consistency, clear error messages, no AI-isms like "I'll help you with that"), accessibility (keyboard navigation, screen-reader labels, focus management, color contrast WCAG AA), edge cases (long strings, special characters, slow networks, offline), transitions and motion (respects `prefers-reduced-motion`, no jank), and surface-specific polish (dark mode if relevant, RTL if relevant, responsive breakpoints). Pass this checklist as part of the prompt — `excellence-reviewer` does not have a built-in `enterprise-polish` mode; the framing lives at the dispatch site so the reviewer evaluates against the same bar the user implicitly set.
    5. Run the strongest meaningful verification for the wave's domain.
    6. Commit with title `Wave N/M: <surface> (F-xxx, F-yyy, ...)` and a body listing each finding ID and what changed.
    7. Update each finding's status in `findings.json` (✓ shipped / ⚠ deferred / ✗ rejected) with commit SHA and any notes.
    8. **If a wave reveals a new finding** (review uncovered something the council missed, or implementation surfaced an adjacent defect that meets the Serendipity Rule), append it to the master list with `record-finding-list.sh add-finding <<< '{"id":"F-NNN","summary":"...","severity":"...","surface":"..."}'` and either fold it into the current wave (if same surface, bounded fix) or assign it to a new follow-on wave with `assign-wave`. Do NOT silently fix it without recording — that breaks the per-finding traceability the protocol exists to provide.

5. **Final summary after all waves.** Present:
    - Master finding-list table: every ID → status with commit SHA or deferral reason.
    - Aggregate verification results across waves.
    - Cross-wave concerns surfaced (regressions, conflicts, follow-ups).
    - The `Serendipity:` line for any adjacent fixes per `core.md` rules.

**Resuming a Phase 8 session.** If a session compacts or crashes mid-wave, `findings.json` survives on disk. On resume, do NOT call `record-finding-list.sh init` again — that refuses by default but `--force` would clobber the wave plan and lose every shipped/commit-tracked finding. Instead: run `record-finding-list.sh counts` and `show` to see where execution stands, identify the in-progress wave (`status="in_progress"`), and re-enter at step 4 of that wave. Findings already marked `shipped` are done; pending findings in the in-progress wave still need work.

**Phase 8 is skipped** when the user said "advisory only", "just analyze", "don't act yet", "report only", or similar — in those cases, end at Step 7's presentation.

**Anti-patterns Phase 8 exists to prevent:**
- **Single-shot mega-implementation** — 30 findings in one giant diff; reviewer chokes, real defects slip through.
- **Five-priority clipping** — "council headline said top 5, I'll only ship those" misreads the rank as scope. The rank is for presentation; execution covers all findings unless the user said otherwise.
- **Cross-session handoff after wave 1** — "I'll do wave 2 next session" violates the segmentation rule in `core.md`. Waves are in-session structure, not cross-session phasing.
- **One mega-commit with no per-finding traceability** — kills bisectability, code review, and rollback.
- **Re-init clobbering on resume** — calling `init` on an already-populated wave plan and losing progress. Use `counts` first; `init --force` only when actually starting over.
- **Silent discover-during-execution** — fixing a newly-surfaced defect without recording it in the master list. If it qualifies under Serendipity, it qualifies for an `add-finding` entry too.

## Execution style

- **Challenge the project, don't praise it.** The value is in what's missing or wrong. Strengths get a brief mention, not a celebration.
- **Be specific.** "Improve error handling" is useless. "The /api/users endpoint returns a 500 with a stack trace when the email field is missing — return a 400 with a clear message" is useful.
- **When lenses disagree, present the tension.** Don't resolve it — the user decides priorities.
- **Ground everything in evidence.** Every finding should reference a file, flow, or concrete observation.
- **Prioritize ruthlessly.** A project with 47 findings needs 5 priorities, not 47 equal-weight items.
