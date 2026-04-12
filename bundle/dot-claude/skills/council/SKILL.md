---
name: council
description: Multi-role project evaluation that dispatches expert perspectives (PM, design, security, data, SRE, growth) to surface blind spots and unknown unknowns a solo developer would miss.
argument-hint: "[optional focus or project path]"
disable-model-invocation: true
model: opus
---
# Project Council

Evaluate this project from multiple professional perspectives to surface blind spots, unknown unknowns, and cross-cutting concerns that no single role would catch alone.

$ARGUMENTS

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

### 6. Present

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
Each finding: what it is, which lens found it, why it matters, concrete fix

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
