---
name: manuscript
description: Academic manuscript workflow — structure, verified citations, drafting, and rigor critique for papers, theses, proposals, and referee responses. Sequences evidence before prose so every citation is registry-verified before it is written.
argument-hint: "<manuscript task — draft, revise, respond to referees>"
disable-model-invocation: true
---
# Academic Manuscript

Produce or revise an academic manuscript to a submission-credible standard: structure decided before drafting, every citation verified before it is written, claims audited before it is called done.

Primary task:

$ARGUMENTS

## Research-Craft Calibration

Full doctrine: `~/.claude/quality-pack/research-craft/citation-integrity.md` (references), `~/.claude/quality-pack/research-craft/figure-craft.md` §1 (captions carry the argument). Inline baseline:

- **Verify-before-write**: no reference enters the draft until registry-verified this session (Crossref/OpenAlex/Semantic Scholar/arXiv). DOIs are resolve targets, never generation targets. Recalled-but-unverified sources appear only as `[citation needed: <what>]` markers.
- **Existence is not faithfulness**: load-bearing claims get an anchor (quote or section locator) showing the source actually supports them.
- **Numbers come from current analysis outputs** — re-check every quantitative claim against the latest results before submission (stale-numeric-claim reconciliation).
- **Captions stand alone**: what is plotted, method, N, and what the error bars are.

## Workflow — evidence before synthesis, synthesis before polish

1. **Structure** — dispatch `writing-architect` for the section plan: thesis/contribution, IMRaD skeleton (abstract = context → gap → approach → key result → implication), evidence plan per section, target journal/format constraints (length, reference style, figure count).
2. **Evidence** — dispatch `literature-scout` to verify every source the outline needs BEFORE drafting begins. Its verified-record table is the only citation pool the draft may use. Gaps come back as explicit `[citation needed]` markers, not fabricated fillers.
3. **Draft** — dispatch `draft-writer` with the structure + verified records + analysis outputs. LaTeX projects: edit the project's `.tex`/`.bib` in place, matching its macros and journal class (`revtex`, `achemso`, `elsarticle`, …); BibTeX entries generated from registry metadata only. Typeset quantities with `siunitx` (`\SI{77.5}{\micro\siemens}`, `\num{2.5e-5}`) when the project uses it — value ± uncertainty with units set consistently is the typographic half of the rigor doctrine's units mandate.
4. **Critique** — `editor-critic` for argument/structure/prose AND, whenever the manuscript makes quantitative claims, `rigor-reviewer` for methods, statistics, figure compliance, and claim-citation support. Act on findings; stricter verdict wins.
5. **Reconcile and close** — re-run the citation audit on the final text (every citation still verified, no `[citation needed]` markers remaining unless the user explicitly accepts them), reconcile every number against current analysis outputs, and confirm figures/captions pass `figure-craft` §7.

## Referee-response mode

When the task is a response to reviewers: quote each referee point verbatim, answer point-by-point (what changed, where — page/line/figure), never concede-and-ignore, and keep the tone collegial and factual. New claims added in response to referees get the same verify-before-write treatment as the original draft. Track manuscript deltas explicitly so the response letter and the diff agree.

## Execution rules

- Follow all `/autowork` operating rules: verify, review, don't stop early.
- The stage order is load-bearing: scout before draft (verification precedes writing), critique before done.
- LaTeX verification: compile when the toolchain is available (`latexmk -pdf`, or the project's build command) and fix errors/warnings that affect output; when no toolchain exists, say so and hand the user the exact build command to run.
- A draft with unverified citations is not done — surfacing the unverified list is part of the deliverable.
