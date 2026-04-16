# Usage Examples

Prompts can be prefixed with `/ulw`, `ulw`, `/autowork`, or `/ultrawork` to activate the full harness. All four are equivalent. The system classifies intent and domain automatically, then routes to the appropriate specialist chain.

Add `ultrathink` to any prompt to force deeper investigation -- verification over abstraction, reading source over reasoning about it.

## Autonomy behavior

In ulw mode Claude defaults to action and only pauses for one of five specific cases:

1. **Credentials or external accounts.** Credentials, payment, account access, or an external-account action is required.
2. **Destructive data loss.** The next step would delete or overwrite user data in a non-recoverable way.
3. **Product-taste or policy judgment.** A decision only the user can make — pricing, brand voice, data-retention policy, release-note attribution.
4. **Unfamiliar in-progress state.** The repository contains untracked files, unpushed branches, or stashes whose intent cannot be recovered.
5. **Credible-approach split.** Two credible approaches exist and choosing wrong would cost significant rework.

Any decision outside these five — library choice inside a plausible set, refactor scope, test framework — is made autonomously, stated briefly, and executed. If you want Claude to ask more, add `checkpoint` or `ask before X` to the prompt.

The canonical, always-loaded source for this list is `bundle/dot-claude/quality-pack/memory/core.md` ("Workflow" section). If that file and this section drift, `core.md` wins.

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
