# Design Surface Smoke Prompts

The third v1.15.0-deferred design item — "smoke-test the design surface
end-to-end on real prompts" — cannot be automated because it requires
subjective judgment of visual output. The harness routes prompts to
the right agent with the right contract scaffold, but only a human can
say whether the produced UI is "world-class" vs "competent but
forgettable."

This file is the concrete artifact the user can use to drive that test.
Run each prompt in a fresh fixture project (e.g., `mkdir scratch &&
cd scratch && git init`) and judge the output against the success
criteria below.

## How to use this file

1. Pick any prompt from §"Canonical prompts" below.
2. Open a new Claude Code session in a clean fixture directory
   (or use `git stash` to isolate from your current work).
3. Run `/ulw <prompt>` and let the harness route + execute fully.
4. Score the output against the §"What 'world-class' looks like"
   rubric.
5. Optionally re-run with one of the §"Variation prompts" to check
   the cross-session anti-anchoring advisory fires when expected.

## Canonical prompts (one per platform × domain)

| # | Platform | Domain | Prompt |
|---|---|---|---|
| 1 | web | fintech | `/ulw build me a landing page for a B2B treasury management platform` |
| 2 | web | wellness | `/ulw build me a landing page for a sleep-tracking app` |
| 3 | web | devtool | `/ulw build me a developer-portal homepage for a database company` |
| 4 | iOS | fintech | `/ulw build me an iOS expense-tracker app with native HIG iOS 26 design` |
| 5 | iOS | creative | `/ulw build me an iOS journaling app with a distinctive visual signature` |
| 6 | macOS | devtool | `/ulw build me a macOS menu-bar app for clipboard history` |
| 7 | CLI | devtool | `/ulw polish my CLI tool's --help output and error messages` |
| 8 | CLI | utility | `/ulw build me a terminal task-tracker with a TUI` |

## Variation prompts (test cross-session anti-anchoring)

After running prompt #1 above in a fixture project (the harness will
log the chosen archetype to `~/.claude/quality-pack/used-archetypes.jsonl`),
run a SECOND prompt in the same project:

- Same domain: `/ulw build me a pricing page for the same platform`

The router should inject the "Prior archetypes in this project" advisory
once the project has ≥2 priors logged. Watch the prompt-router context
in `~/.claude/quality-pack/state/<session>/session_state.json` — the
`last_user_prompt` and `ui_domain` fields will reflect the last UI work.

To verify the advisory fired, run `/ulw-report week` and check the
"Design archetype variation" section.

## What "world-class" looks like

Score each output against five rubric items. A "world-class" pass means
4+ of 5 land cleanly.

1. **Specific palette.** Hex values are committed (e.g., `#0F1115`,
   `#7CFFB2`), not framework defaults (`blue-500`, `.systemBlue`,
   `accent-color`). Semantic roles are named (background / surface /
   accent / text-primary / text-muted / border).

2. **Designed typography.** Display + body distinction. Weight, size,
   line-height, letter-spacing all specified. NOT "Inter at default
   weight throughout" or "SF Pro at default everywhere."

3. **Visual signature.** At least one distinctive element — a
   gradient that conveys data, an asymmetric hero, an unusual card
   shape, a bold accent used sparingly, an unexpected typographic
   choice. If you can swap the brand name and the page is
   indistinguishable from "any SaaS landing page" or "any default
   SwiftUI sample," that's a fail.

4. **Anti-archetype-clone.** Output names a closest archetype (e.g.,
   "Stripe-inspired") AND commits to ≥3 things done **differently**
   from that archetype. Direct cloning is a fail.

5. **Cross-generation discipline (after running ≥2 prompts).** The
   second prompt's output uses a DIFFERENT typography choice, palette
   structure, or layout pattern from the first. If both default to
   "Space Grotesk + black-on-white + centered hero", the
   cross-generation discipline failed.

## What "competent but forgettable" looks like (failure mode)

- Tailwind defaults (`blue-500`, `text-gray-700`)
- Inter at default weight, no typographic hierarchy beyond size
- Three identical feature cards in a row with icon + title + description
- Centered hero + CTA over a gradient background
- Stock-illustration SVGs
- Generic "Get Started" / "Learn More" CTA copy
- iOS: `.systemBlue` everywhere, default tab bar, no Dynamic Type, no
  Liquid Glass on iOS 26+
- CLI: rainbow ANSI on every line, no `NO_COLOR` respect, generic
  `Error:` prefix, no `--help` examples

## Reporting

When you complete a smoke run, capture:

1. Which prompt(s) you ran
2. Score on the 5-item rubric (0-5)
3. One sentence per failure mode you saw
4. Whether the cross-session advisory fired on the second prompt
5. Whether the inline contract was captured (check
   `~/.claude/quality-pack/state/<session>/design_contract.md`)
6. Whether `design-reviewer` cited the inline contract in its findings

A short PR comment or GitHub issue with these fields is enough — the
goal is to find systemic gaps, not exhaustively grade every output.

## What's deliberately NOT in this fixture

- **Automated assertion of visual quality.** Subjective; brittle.
  Manual judgment only.
- **Real fixture projects.** This file is platform-agnostic prose; the
  user provides the scratch directory.
- **Recorded "expected output" baselines.** LLM output varies across
  runs; baselines would create false-positive churn.

## Status

- v1.16+ candidate: an automated routing-correctness test that
  asserts "given prompt X, the router injects platform Y, tier Z,
  archetype family W, and routes to agent A" — that's mechanizable
  but doesn't substitute for subjective judgment of the produced UI.
- Last updated: 2026-04-26 (post-commit `0c9edd1`).
