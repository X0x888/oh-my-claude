# Showcase — quality gates in the wild

This page collects real-world transcripts where oh-my-claude's quality gates caught a bug, missing test, or stalled completion that Claude Code was about to ship. The goal is concrete proof: "Claude was about to mark this done, the gate stopped it, and here's what changed."

If you have a session where the harness saved you, send it in. Pull requests welcome — see [Contributing your own](#contributing-your-own) at the bottom.

## How to read each entry

Each showcase has the same shape so you can scan quickly:

- **Setup** — repo type and what the user asked for in one line.
- **Block** — the exact gate message that fired.
- **Resolution** — what Claude did to satisfy the gate (the "second take").
- **Counterfactual** — what would likely have shipped without the gate.

Two minutes is the budget per entry. If a transcript can't be summarized in that time, it's too long.

## Entries

> **This page is a placeholder.** No community submissions have landed yet. The format below shows what an entry will look like once the first submissions arrive — until then, the most concrete thing you can do is run `/ulw-demo` yourself and feel the gates fire on a synthetic file.

### Example shape (synthetic, for illustration only)

> **Setup.** Node/Express repo. User asked: `/ulw add a /me endpoint that returns the current user`.
>
> **Block.** `[Quality gate · 1/3] The deliverable changed but the final quality loop is incomplete.`
>
> **Resolution.** Claude had written the route but skipped the test for the unauthenticated 401 path. The block surfaced a missing test; Claude added a Jest case and re-ran. The reviewer then flagged that the route was missing CORS headers under the existing project convention. Both addressed in one follow-up commit.
>
> **Counterfactual.** Without the gate, the deliverable would have shipped with a passing happy-path test and a missing 401 case — exactly the regression class the project's CI suite was added to catch.

This is the rhythm we want for real entries: short, concrete, falsifiable.

## Contributing your own

If `/ulw-report` shows a Serendipity Rule application, a gate-block-then-fix sequence, or any other moment where you felt the harness pull its weight, that's a candidate.

To submit:

1. Trim the transcript to the shape above (Setup / Block / Resolution / Counterfactual). Two minutes of reading max.
2. Strip anything sensitive — internal repo names, credentials, customer data. The gate-block message itself is fine to quote verbatim.
3. Open a PR adding your entry under `## Entries` above the placeholder. Add yourself in the entry's footer (`— @yourname`, optional).
4. If you'd rather not have your transcript in the repo, you can also link to a gist or blog post — the page accepts both inline entries and outbound links.

Reviewers will edit for length and tone before merging. The page's purpose is to make the harness's value concrete to a skeptical first-time visitor; entries that don't move that needle will be politely declined or asked for revision.

---

_See also: [`/ulw-demo`](../bundle/dot-claude/skills/ulw-demo/SKILL.md) for a guided synthetic walkthrough · [`/ulw-report`](../bundle/dot-claude/skills/ulw-report/SKILL.md) for cross-session activity digests · [docs/glossary.md](glossary.md) for the names you'll see in transcripts._
