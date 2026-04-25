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

> The entry below is a **synthetic seed** so you can see the format in context. Real community submissions go above it under `## Entries` — replace or push this seed down as the page fills up.

### v1.14 — Phase 8 wave-cap regression caught in vitro before in vivo *(synthetic seed)*

> **Setup.** This very repo (`oh-my-claude`). The author was running a v1.14 quality wave that, among other things, extracted a verification subsystem to `lib/verification.sh`. As a deferred-from-v1.13 follow-up, the wave also needed to close an integration gap: `record-finding-list.sh` and `stop-guard.sh` had each been tested in isolation, but the contract that binds them — `wave_total` from `findings.json` raises the discovered-scope gate's block cap from 2 to `wave_total + 1` — had no integration test.
>
> **Block.** `[Discovered-scope gate · 1/5] 4 finding(s) from advisory specialists were captured this session but not addressed in your final summary. Wave plan: 0/4 waves completed.`
>
> **Resolution.** A new `tests/test-phase8-integration.sh` (18 assertions, 4 scenarios) was added that wires both halves end-to-end against a real `findings.json` and a real `discovered_scope.jsonl`. The first run flagged that the JSON-encoded middle-dot character (`·` baked into `stop-guard.sh`'s reason text) needed a literal-escape substitution for stable assertions. The second run flagged that the `Wave plan: X/N waves completed` text advanced correctly only after `wave-status completed` was called, not on `wave-status in_progress`. Both edge cases now have explicit assertions.
>
> **Counterfactual.** Without the integration test, a future refactor of `read_active_wave_total` or `read_active_waves_completed` could have silently broken the cap formula — the unit tests would still pass, but the gate would either over-block (cap stuck at 2) or under-block (cap unbounded). The deferred-risk note was already in memory; the wave plan turned it into a regression net.

Format we want for real entries (cribbed from the seed above): short, concrete, falsifiable. If your transcript can't be summarized in two minutes of reading, it's too long.

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
