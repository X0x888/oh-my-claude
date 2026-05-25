# Usage Examples

Prompts can be prefixed with `/ulw`, `ulw`, `/autowork`, or `/ultrawork` to activate the full harness. All four are equivalent. The system classifies intent and domain automatically, then routes to the appropriate specialist chain.

Add `ultrathink` to any prompt to force deeper investigation -- verification over abstraction, reading source over reasoning about it.

## Autonomy behavior

In ulw mode Claude defaults to action and only pauses for one of five **operational** cases (v1.40.0):

1. **Credentials or external accounts.** A credential, payment, account access, or external-account action the agent literally cannot supply. A missing INPUT, not a decision.
2. **Hard external blocker.** Rate limit hit, paid API quota exhausted, dead build/test infra, or a dependency upgrade pending in a tracked external ticket the agent cannot resolve.
3. **Destructive data loss on shared state.** The next step would delete or overwrite user data in a non-recoverable way (drop a prod table, force-push `main`, `rm -rf` against unstaged changes).
4. **Unfamiliar in-progress state.** Untracked files, unpushed branches, or stashes whose intent cannot be recovered by inspection — risk of clobbering work in flight.
5. **Scope explosion without pre-authorization.** A council or planner surfaced ≥10 findings AND the prompt did not explicitly authorize exhaustive implementation.

Anything outside these five — **including** product-taste judgment, brand voice, data-retention policy, release-note attribution, library choice within a plausible set, refactor scope, test framework, and credible-approach splits — is the agent's call under ULW with default `no_defer_mode=on`. It picks the option a senior practitioner would defend, names alternatives ruled out in one line, and ships. You can redirect cheaply in real time if the call is wrong; a held-but-undecided session costs you everything.

If you want the legacy v1.39-era "pause for taste / policy / credible-approach" behavior, set `no_defer_mode=off` in `~/.claude/oh-my-claude.conf`. If you want Claude to ask more on a specific prompt, add `checkpoint` or `ask before X` to the prompt itself.

The canonical, always-loaded source for this list is `bundle/dot-claude/quality-pack/memory/core.md` ("Maximum-Autonomy Defaults" → "Workflow" section). If that file and this section drift, `core.md` wins.

---

## Coding

```
/ulw debug why settings saves but shows stale data until page refresh
```
Triggers a coding-domain execution. Claude will reproduce the issue, form a hypothesis, trace the data flow, fix the root cause, add a regression test, and run the reviewer before stopping.

```
/ulw migrate the user table from Postgres to the new schema, keep backward compat
```
Planning-heavy coding task. Claude will delegate to a planner or prometheus for the migration strategy, implement incrementally, run tests after each step, and verify backward compatibility.

```
/ulw add unit tests for the payment processing module -- cover edge cases and error paths
```
Test-focused execution. Claude identifies the module, reads existing coverage, writes targeted tests for boundary conditions and failure modes, runs them, and reviews the test quality.

```
/ulw refactor the auth middleware to use the new session store, update all call sites
```
Cross-cutting refactor. Claude will map all call sites first, plan the change sequence, make incremental edits with verification between each, and run the full test suite before stopping.

---

## Writing

```
ulw draft a project proposal for migrating our data pipeline to event-driven architecture
```
Writing-domain execution. Claude uses writing-architect for structure, draft-writer for the content, and editor-critic for review. The proposal targets the stated audience and covers motivation, architecture, risks, and timeline.

```
/ulw write a post-mortem for the March 15 outage -- audience is engineering leadership
```
Structured writing with a specific audience. Claude will clarify the format expectations, draft the timeline/impact/root-cause/remediation sections, and polish for an executive audience.

```
ulw draft a cover letter for the senior engineering manager role at Stripe
```
Professional writing. Claude structures the letter around the role requirements, drafts with appropriate tone, and runs editor-critic to tighten the prose and remove filler.

```
/ulw what structure should this grant proposal use?
```
Writing-domain advisory. Claude answers directly with structural guidance, audience fit, and evidence expectations rather than trying to draft the whole piece unless you explicitly ask it to.

```
/ulw research the literature on spaced repetition in graduate study and draft a short literature review with citations
```
Scholar-style mixed workflow. Claude gathers authoritative sources via librarian, uses briefing-analyst to synthesize the evidence, drafts the review with citation-shaped placeholders where needed, and runs editor-critic before finalizing.

---

## Research

```
/ulw compare server-session auth vs JWT for our mobile API -- recommend one
```
Research-domain execution. Claude uses librarian for authoritative sources, briefing-analyst to synthesize tradeoffs, and metis to stress-test the recommendation. The deliverable is a decision-ready brief.

```
/ulw audit the iOS app's dependency tree for security risks and licensing issues
```
Codebase advisory. Claude reads the actual dependency manifests, checks for known vulnerabilities, flags license incompatibilities, and grounds every finding in the real dependency list.

```
ulw evaluate whether we should adopt Turborepo or Nx for our monorepo -- we have 12 packages
```
Comparative research with project context. Claude gathers current docs on both tools, maps them against the stated constraints (12 packages), and delivers a ranked recommendation with tradeoffs.

```
/ulw what are the tradeoffs between spaced repetition and active recall for graduate study?
```
Research-domain advisory. Claude answers directly instead of forcing implementation, but still keeps the research discipline: source quality first, evidence separated from inference, and a decision-oriented comparison rather than generic brainstorming.

```
/ulw analyze the spreadsheet of quarterly revenue, churn, and acquisition cost trends and draft a KPI decision memo
```
Quantitative mixed workflow. Claude treats the numbers as evidence, uses `data-lens` when metric quality or instrumentation trust is load-bearing, synthesizes with `briefing-analyst`, and drafts a memo that includes a compact metric summary or scenario matrix instead of prose-only conclusions.

```
/ulw what does this contract clause imply for vendor liability in the UK?
```
Regulated advisory workflow. Claude answers directly, but treats current authority and scope boundaries as load-bearing: it grounds the answer in the contract text and current governing sources, names the jurisdiction and effective-date assumptions, and avoids inventing legal obligations or false certainty.

```
/ulw draft a HIPAA compliance remediation memo for the patient-data workflow
```
Regulated mixed workflow. Claude uses librarian and briefing-analyst to ground the requirements and implications, then drafts the memo with sign-off boundaries, unresolved scope assumptions, and governing-source caveats carried into the final artifact instead of buried in reasoning.

---

## Operations

```
ulw turn these meeting notes into an action plan with owners, deadlines, and a follow-up email
```
Operations-domain execution. Claude uses chief-of-staff to structure the deliverable: extracts action items, assigns owners, sets deadlines, drafts the follow-up email, and reviews with editor-critic.

```
/ulw create a sprint planning checklist for the Q3 platform migration
```
Planning deliverable. Claude structures the checklist around the migration phases, adds dependency tracking, flags risks, and formats for team use.

```
ulw draft a stakeholder update email summarizing this week's progress on the payments integration
```
Professional communication. Claude structures the update (highlights, blockers, next steps), drafts in appropriate tone for stakeholders, and reviews for clarity and completeness.

```
/ulw what is the best way to structure this launch checklist?
```
Operations-domain advisory. Claude answers directly with a recommended checklist shape, sequencing, and ownership discipline instead of turning the question into implementation work.

---

## Native Artifacts

```
/ulw build a budget workbook with forecast formulas and variance tabs
```
Spreadsheet/workbook execution. Claude treats the workbook itself as the deliverable, not a prose description of the workbook. When native spreadsheet tooling is available it should emit the actual `.xlsx`/workbook artifact; otherwise it must say so explicitly and provide the closest structured intermediate (sheet-by-sheet schema, formula map, assumptions table, import-ready data) instead of pretending the file exists.

```
/ulw turn this quarterly update into a board presentation deck
```
Presentation/deck execution. Claude preserves the slide-deck deliverable contract: real slides when native deck tooling is available, or an explicit slide-by-slide outline with title, message, evidence, and presenter notes when it is not.

```
/ulw draft a formal policy document in a .docx artifact
```
Document-artifact execution. Claude preserves the `.docx` / Word-style deliverable rather than substituting a loose memo. If native document tooling is unavailable it must say so explicitly and provide a section-by-section structured draft with formatting notes.

---

## Combined Patterns

```
/ulw ultrathink investigate why the CI pipeline is 3x slower since last week
```
Deep investigation mode. `ultrathink` forces Claude to verify every assumption against real data -- reading CI configs, checking recent changes, timing individual steps -- rather than reasoning abstractly about possible causes.

```
/ulw ultrathink review the entire codebase for security issues, focusing on auth and data validation
```
Full codebase audit with deep verification. Claude launches scoped exploration agents (auth layer, data validation, API boundaries), waits for all to return, verifies the highest-impact findings against actual code, then synthesizes.

```
/ulw research the Stripe API changes in v2024-12 then update our payment module to match
```
Mixed domain (research + coding). Claude researches the API changes via librarian, plans the migration, implements the updates, tests, and reviews. The system detects "mixed" domain and uses appropriate specialists for each phase.

```
/ulw fix the deploy-health endpoint, add regression tests, and create a release plan plus cutover checklist with owners, deadlines, and rollback steps
```
Mixed domain (coding + operations). Claude fixes and verifies the implementation work, then uses chief-of-staff to structure the operational artifact so the checklist stays actionable: owners, deadlines, rollback steps, and cutover sequencing stay synchronized with the actual code and verification state.

---

## Session Management

```
/ulw continue
```
Resumes the previous task. Claude picks up from the preserved objective and last assistant state. Does not restart from scratch.

```
/ulw continue -- but skip the frontend tests, they're flaky
```
Continuation with a directive. Claude resumes the prior task but applies the additional instruction ("skip the frontend tests") to the remaining work.

```
/ulw checkpoint
```
Requests a clean pause. Claude summarizes what is done and what remains, then stops without being blocked by the stop guard.

```
should I start a new session or continue here? context is at 60%
```
Session management question. Claude answers directly with a recommendation about session strategy, without launching into implementation.

```
what's the tradeoff between fixing this now vs deferring to next sprint?
```
Advisory question mid-task. Claude answers the question directly using the current task context, then preserves the active objective in the background. Does not force implementation.
