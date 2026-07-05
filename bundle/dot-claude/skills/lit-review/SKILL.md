---
name: lit-review
description: Verified academic literature review — finds papers and returns registry-verified sources (Crossref/OpenAlex/Semantic Scholar/arXiv) with claim-support anchors and honestly-marked gaps. Never cites from model memory.
argument-hint: "<topic, question, or claim to ground>"
disable-model-invocation: true
context: fork
agent: literature-scout
---
Survey the academic literature on the topic below and return verified sources the main thread can cite.

$ARGUMENTS

Requirements — per `~/.claude/quality-pack/research-craft/citation-integrity.md`:

- **Verify-before-write**: every returned source is registry-verified in this session (Crossref / OpenAlex / Semantic Scholar / arXiv). DOIs and arXiv IDs are resolve targets, never generation targets.
- Label each source's verification level: existence / abstract-checked / full-text-anchored. Cross-check load-bearing records in a second registry.
- For claim-grounding requests, deliver the claim-support map (claim → source → anchor → verdict), not just a reading list.
- Mark candidates that could not be verified under `UNVERIFIED — do not cite`, with what was searched.
- Generate BibTeX from registry metadata (never freehand) when requested; prefer published versions over preprints.
- Finish with a recommended reading order and the 2-3 sources the deliverable should lean on hardest.
