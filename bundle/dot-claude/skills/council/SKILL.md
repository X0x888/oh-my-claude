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

- `--deep` — Escalate all dispatched lenses to `model: opus` for deeper reasoning. Default is the lenses' built-in `model: sonnet`. Use when the project is high-stakes, the user explicitly asked for a thorough audit, or a previous shallow pass missed something. Cost is meaningfully higher (each lens runs on opus instead of sonnet); reserve for cases where depth is the bottleneck. Detection: if `$ARGUMENTS` contains `--deep` as a standalone token, set DEEP_MODE for the rest of this protocol.

## Agentic protocol (load-bearing — re-read after any compaction)

Before any dispatch, anchor on these rules so they survive context pressure:

1. **Ground every finding in evidence.** A finding without a file path, line number, or concrete observed behavior is opinion, not output. Lens agents are instructed to do this; if a returned lens skipped citations, name the gap in the synthesis instead of repeating the unsupported claim.
2. **Do not synthesize on partial returns.** If any dispatched lens has not returned, report what is in flight and continue waiting. Synthesis on a partial set silently biases the final assessment toward whichever lens responded fastest.
3. **Verify the top of the stack before presenting.** The top 2-3 findings drive the user's actions. Re-verify each one against the actual code before they ship in the final assessment (Phase 7 below). Surface-level lens claims that fail verification are noise, not signal.
4. **Preserve tensions, do not synthesize them.** When two lenses contradict, surface both in the "Cross-Perspective Tensions" section. A clean synthesis that hides a real disagreement is worse than no synthesis.
5. **The five-priority rule.** A project with 47 findings needs 5 priorities, not 47 equal-weight items. If the synthesis emerges with more than 5 critical findings, you have under-prioritized — pick the top 5 by impact x reach.

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
| `design-lens` | Web apps, mobile apps, desktop apps, CLIs with interactive UX | Libraries, APIs, backend services, infrastructure |
| `security-lens` | Anything with auth, user data, external APIs, network exposure | Static sites with no data, read-only tools |
| `data-lens` | Products needing analytics, data-driven decisions, ML features | Early prototypes, pure infrastructure, CLI utilities |
| `sre-lens` | Production services, APIs, infrastructure, anything that runs 24/7 | Client-only apps, libraries, documentation |
| `growth-lens` | Consumer products, SaaS, marketplaces, open-source with adoption goals | Internal tools, infrastructure, scripts |

**Minimum 3 lenses, maximum 6.** If fewer than 3 are relevant, include product-lens and security-lens by default — they apply to almost everything.

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

### 6. Verify top findings (Phase 7 of execution, named here for ordering)

Before presenting the final assessment, the top 2-3 highest-impact findings drive the user's most consequential actions. Surface-level lens output is not enough on findings that load-bearing. Verify each one with a focused dispatch:

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
Mark verification status: ✓ verified (Phase 7), ◑ refined, or ✗ demoted/dropped during verification.

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

## Execution style

- **Challenge the project, don't praise it.** The value is in what's missing or wrong. Strengths get a brief mention, not a celebration.
- **Be specific.** "Improve error handling" is useless. "The /api/users endpoint returns a 500 with a stack trace when the email field is missing — return a 400 with a clear message" is useful.
- **When lenses disagree, present the tension.** Don't resolve it — the user decides priorities.
- **Ground everything in evidence.** Every finding should reference a file, flow, or concrete observation.
- **Prioritize ruthlessly.** A project with 47 findings needs 5 priorities, not 47 equal-weight items.
