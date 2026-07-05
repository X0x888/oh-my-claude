# Citation Integrity Doctrine

On-demand reference for `literature-scout`, `rigor-reviewer`, `draft-writer`, `editor-critic`, and the `/lit-review` + `/manuscript` skills. NOT in the global `@`-include chain — loaded when literature or manuscript work is in play.

Fabricated references are the single most damaging LLM failure mode in academic writing: they survive drafts, pass casual review, and detonate under a referee's DOI click. This file makes fabrication structurally difficult rather than merely discouraged.

## §1. The iron rule: verify-before-write

**No reference enters a draft, bibliography, or BibTeX file until it has been verified against a live registry in the current session.** Not "verified later", not "I recognize this paper" — model memory of bibliographic fields is exactly the thing being defended against. Field-accuracy studies find the DOI is the *least* accurately free-generated bibliographic field, which yields the operational rule:

> **DOIs and arXiv IDs are resolve targets, never generation targets.** Look them up; never type one from memory.

The verified-entry record for each citation: title, authors, venue, year, DOI (and/or arXiv ID), and the retrieval date. Anything less is a lead, not a citation.

## §2. The verification loop

1. **Candidate** — a claim needs support; a paper is recalled or found by search.
2. **Registry lookup** — search by title/author (never by guessed DOI) against one of the §3 registries.
3. **Metadata fetch** — pull the canonical record; compare title, authors, year, venue against what was recalled. Near-misses (right group, wrong paper; right paper, wrong year) are the common fabrication shape — treat "close" as "wrong" until reconciled.
4. **Cross-check when load-bearing** — for claims the argument depends on, confirm the same record in a **second independent registry** (e.g., Crossref + OpenAlex, or Semantic Scholar's `externalIds` crosswalk). A record resolving in one index but absent everywhere else is a fabrication signal.
5. **Record** — write the verified entry (§1 fields) into the working bibliography with the retrieval date.

## §3. Keyless registry endpoints

All four work without API keys and are callable with `curl` (endpoint shapes live-verified 2026-07). Send an identifying `mailto` where supported — it is both etiquette and better service.

- **Crossref** — canonical DOI registry.
  `https://api.crossref.org/works/{DOI}?mailto=you@example.com` → JSON `message` with title, container-title, authors, dates.
  Search: `https://api.crossref.org/works?query.bibliographic={title words}&rows=5&mailto=...`
  The `mailto` parameter opts into the "polite pool" (better rate limits, signaled via `X-Rate-Limit-*` response headers).
- **OpenAlex** — open scholarly graph.
  `https://api.openalex.org/works/doi:{DOI}?mailto=you@example.com` → id, title, publication_year, cited_by_count, referenced_works.
  Keyless access verified working as of 2026-07; if it returns 401/403, registration for a free key is the documented fallback.
- **Semantic Scholar** — richest ID crosswalk.
  `https://api.semanticscholar.org/graph/v1/paper/DOI:{DOI}?fields=title,year,externalIds,venue` — `externalIds` maps DOI ↔ arXiv ↔ CorpusId. Also accepts `arXiv:{id}` as the path key. Unauthenticated pool is shared; back off on 429.
- **arXiv export API** — for preprints.
  `http://export.arxiv.org/api/query?id_list={YYMM.NNNNN}` → Atom XML, one `<entry>` per paper.
  Title search: `?search_query=ti:"exact title words"&max_results=5`. Official etiquette: ≤1 request per 3 seconds, single connection.

When a docs/paper-search MCP server (Zotero, arXiv, Semantic Scholar) is connected, prefer it over raw curl — same rule, better tooling.

## §4. Existence is not faithfulness

Verifying that a paper **exists** does not verify that it **supports the claim** it is cited for. These are separate checks with separate failure modes:

- **Existence check** (§2): the bibliographic record is real and correctly transcribed.
- **Faithfulness check**: the cited work actually says what the sentence claims. For every load-bearing claim, fetch the abstract (registries return it) or the relevant section when accessible, and anchor the support: a short quote or a section/figure locator recorded alongside the citation. When full text is unreachable, mark the citation `[existence-verified; claim unverified against full text]` in working notes and say so if it matters.
- **Citation laundering** is the subtle failure: citing paper A for a claim A itself only cites from paper B. When the claim is central, chase it to the primary source and cite that.

## §5. BibTeX and reference-list hygiene

- **Generate entries from registry metadata**, never freehand. Crossref serves BibTeX directly: `curl -LH "Accept: application/x-bibtex" https://doi.org/{DOI}`.
- **Stable, predictable keys** (`surnameYEARkeyword`), one entry per work, no duplicate records under variant keys.
- **Preprint vs published version**: when a published version exists, cite it (with DOI); cite the arXiv version only when it is genuinely the referenced artifact, and pin the version (`v2`) when the difference matters.
- **Journal-style compliance** (abbreviated vs full journal names, author-count truncation) is applied at the end, from the verified records — style reformatting must never re-type fields by hand.
- **Retraction awareness**: for load-bearing citations, glance at the Crossref record's `update-to`/retraction flags — citing retracted work unknowingly is a real referee catch.

## §6. Failure-mode catalog

The shapes to actively hunt during review (each is a real observed LLM pattern):

1. **Plausible fabrication** — right authors, plausible title, real venue, no such paper.
2. **Chimera** — title from one paper, authors from another, year from a third.
3. **Year/venue drift** — real paper, off-by-one year or predecessor journal.
4. **Checksum-plausible dead DOI** — well-formed `10.xxxx/...` that resolves nowhere.
5. **Real source, wrong claim** — the existence check passes; the faithfulness check (§4) fails.
6. **Laundered chain** — the claim's actual origin is two citation hops away and mutated en route.
7. **Stale numeric claim** — the manuscript quotes a number ("2,847 traces") that a later analysis run changed; reconcile manuscript numbers against current analysis outputs whenever the analysis has been re-run (claim-reconciliation).

## §7. When verification fails

- Registry conflict → present the conflict; prefer the DOI-registering agency (Crossref) for bibliographic fields.
- Lookup finds nothing → the reference does not go in. Mark the claim `[citation needed — candidate not found: <what was searched>]` visibly in the draft. An honest gap survives review; a fabricated filler does not.
- Rate-limited / offline → queue the verification explicitly; never promote a queued candidate to a bare citation because the draft "looks done". The draft is not done while unverified markers remain — surfacing them is part of the deliverable.

## §8. How agents use this file

- `literature-scout` runs §2 on every source it returns and §4 faithfulness anchoring on every claim-source pairing; its output is verified records, never bare recollections.
- `draft-writer` inserts citations only from the session's verified-record set; recalled-but-unverified sources go in as `[citation needed]` markers for the scout.
- `rigor-reviewer` and `editor-critic` audit drafts against §6 — every flagged citation names the suspected failure mode.
- `/manuscript` sequences scout-before-draft so verification precedes writing (§1), and re-runs claim-reconciliation (§6.7) before declaring a revision done.
