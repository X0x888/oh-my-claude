---
name: diverge
description: Generate 3-5 alternative framings of a problem BEFORE committing to one. Use upstream of `quality-planner` when the task admits multiple credible approaches and choosing the wrong shape would cost rework. Distinct from prometheus (interview to clarify WHAT to build), metis (stress-test a draft plan), oracle (debug second opinion), and abstraction-critic (critique an existing artifact's paradigm fit). Divergent-framer expands the option space; the others narrow it.
allowed-tools: Agent
---

# /diverge — Expand the option space before commit

Use `/diverge <task>` when the task admits multiple credible framings and you want to see them side-by-side with explicit tradeoffs *before* a planner commits to one.

## When to use

- Open-ended prompts: *"how should we approach the rate-limit handling?"*, *"what's the best architecture for this?"*, *"is there a better way to do X?"*
- Architecturally significant choices where the paradigm decision is non-obvious (event-sourced vs CRUD, push vs pull, sync vs async, monolith vs services, library-build vs use-existing).
- The model has stated an interpretation and you want to verify it covers the space before commit.
- A council surfaced findings that disagree on framing — the lenses are pointing at different shapes of solution.

## When NOT to use

- Single-line bug fixes, well-scoped refactors, or any task with an obvious dominant approach. Adding `/diverge` to routine work is friction, not value.
- Tasks already mid-execution. `/diverge` is upstream-only — once a planner has committed to a paradigm, use `metis` to stress-test it or `abstraction-critic` to question the fit.
- Debugging. Use `oracle` for "what's the root cause?" and `metis` for "what's wrong with this plan?".

## How it works

The skill dispatches the `divergent-framer` agent with your task. The agent emits a structured menu:

- **3-5 framings**, each with: a 2-4 word name, the mental model in one sentence, what the paradigm makes EASY (1-2 concrete affordances), what it makes HARD (1-2 concrete costs), and the best-fit conditions.
- **A one-paragraph rank** picking the strongest fit for the stated constraints with a "redirect if" clause naming the condition under which a different framing would win.

The agent does NOT produce implementation plans (that's `quality-planner` / `prometheus`) or critique existing code (that's `quality-reviewer` / `metis`). The output is the menu, not the recipe.

## Decision tree — divergent vs convergent critics

| Question | Skill | What it produces |
|---|---|---|
| What shapes COULD this problem take? | `/diverge` (divergent-framer) | 3-5 framings + rank |
| WHAT exactly does the user want me to build? | `/prometheus` | Interview-clarified requirements |
| Is THIS plan robust against edge cases? | `/metis` | Plan stress-test findings |
| What's the root cause / best path through this stuck debug? | `/oracle` | Diagnostic + approach recommendation |
| Does this artifact's paradigm match the problem? | `/abstraction-critic` | Paradigm-fit critique on existing code |

`/diverge` runs *upstream* of all of them. The others narrow the answer; `/diverge` expands the option space.

## Example flow

```
/diverge handling rate-limit retries in the resume-watchdog

→ divergent-framer emits:
  Framing 1: pinned-cooldown-with-jitter   — easy: deterministic; hard: thundering herd
  Framing 2: exponential-backoff-with-cap  — easy: handles transient; hard: harder to reason about
  Framing 3: queue-then-replay             — easy: durable; hard: requires storage
  Framing 4: skip-and-notify-only          — easy: simple; hard: user must act
  Rank: Framing 1 because watchdog cooldown is already pinned; Framing 3 if durability becomes a hard requirement.

You pick Framing 1. quality-planner gets a clean target instead of starting from "I think we should...".
```

## Why this exists

oh-my-claude's existing critics (`oracle`, `metis`, `abstraction-critic`, `excellence-reviewer`) are convergent — they narrow toward a single right answer. That convergence is correct *after* the framing is chosen. Before the framing is chosen, the model defaults to the first paradigm that comes to mind — usually the most-recently-seen example or the easiest to articulate, not necessarily the best fit.

`/diverge` is the seam that protects against premature commitment. It's the most-explicit application of the user's "natural divergent thinking ability" axis-6 ask.
