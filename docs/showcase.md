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

The entries below are real catches from this repo's own development history — moments where the harness's gates intercepted a defect before ship and the diff is in `git log` if you want to verify. Community-contributed entries go above these as they arrive.

### v1.36.x W2 — `_v:1` schema-version gap on the gate-skips writer caught at excellence-review

> **Setup.** This repo. Author was wrapping up a 5-finding wave that added cross-session JSONL schema versioning (`_v:1`) to four writers (`record_gate_event`, `record-archetype.sh`, `record_classifier_telemetry`, `record_gate_skip`).
>
> **Block.** Wave 2's excellence-reviewer dispatched on the diff and flagged: *"common.sh:4364 — `record_gate_skip` writer also lacks `_v:1`."* The author had grepped for `record_*` writers but the helper was named `_do_record_skip` (private prefix), missing the surface scan.
>
> **Resolution.** Added `_v:1` to the gate-skips row literal as a wave-append rather than punting to a v1.37 follow-up. Same commit grew an additional same-class fix on `append_discovered_scope`'s row literal (line 5472) — the excellence-reviewer's scan unblocked a sibling pattern check.
>
> **Counterfactual.** Without the second reviewer pass, the wave would have shipped with 5 of 6 cross-session writers schema-versioned and the gate-skips row silently lacking `_v`. The next migration tool (when it lands) would have to special-case the unstamped writer or skip its rows entirely. Catching it pre-commit means the convention holds uniformly going forward.
>
> *— `git log f393986^..HEAD` for the wave commit; `record-finding-list.sh status-line` shows 11/25 shipped at that point.*

### v1.35.0 — shortcut-ratio gate caught a wave plan deferring half its decided findings

> **Setup.** This repo. A long ULW session had emitted a 12-finding wave plan; halfway through, the model started marking findings `deferred` with reasons like *"requires significant effort"* and *"tracks to a future session"* — strings that lexically passed the validator's silent-skip deny-list because they didn't match `out of scope` / `follow-up` / `later`.
>
> **Block.** `[Shortcut-ratio gate · 1/1] wave plan has 6/8 decided findings deferred (75%) on a 12-finding plan. Big-plan majority-deferral is the shortcut-on-big-tasks pattern: even valid-WHY deferrals can satisfy gate counts while leaving the work fundamentally incomplete.`
>
> **Resolution.** The model's recovery: ship 3 of the deferred findings inline, keep 3 deferred but rewrite their reasons to name an external blocker (`requires F-024 first`, `awaiting stakeholder pricing decision`, `superseded by F-051`), and explicitly justify the 50% ratio in the wrap-up summary. The validator's effort-excuse deny-list was extended in the same release to reject `requires significant effort` / `needs more time` / `blocked by complexity` outright.
>
> **Counterfactual.** Pre-v1.35.0 the validator was keyword-based and `requires significant effort` lexically passed. The stop-guard counted decided findings but not ship-vs-defer balance, so deferring the hard half satisfied gate counts. Without this gate, the model would have shipped a wave that looked complete (gates green, all findings decided) but where the substantive work was deferred indefinitely.
>
> *— v1.35.0 CHANGELOG covers the validator + shortcut-ratio gate landings.*

### v1.34.x — Bug B post-mortem caught a 5-release silent state-corruption recovery

> **Setup.** This repo. A user reported "my session keeps thinking it just recovered from corruption" with no actual corruption visible. Investigation traced to `read_state_keys` — a bulk-read helper added in v1.27.0 — silently overflowing the positional-alignment contract when one of the values contained a literal `\n`.
>
> **Block.** The recovery counter sticky marker fired on every prompt; `_ensure_valid_state` archived a "corrupt" `session_state.json` that was actually structurally sound. No gate fired during the recovery (the recovery is silent by design); the user noticed the marker pile-up.
>
> **Resolution.** Post-mortem identified a structural failure: the harness exempted itself from the `quality-pack/council` evaluation that's pointed at every other project. Wave fix: introduce a fixture-realism rule (every test fixture must reproduce real-world value shapes — newlines, control bytes, multi-line JSON), backfill 23 state-IO regression tests with adversarial values, and run `/council --self-audit` quarterly against the harness itself.
>
> **Counterfactual.** Without the post-mortem, the bug would have continued silently archiving session state on every prompt for arbitrarily long. Each recovery is a state-loss event the user doesn't see. The fixture-realism rule (now in `CONTRIBUTING.md`) is the structural defense that keeps similar bugs from surviving five releases again.
>
> *— v1.34.0 release notes; `tests/test-state-io.sh` T19/T20 are the regression net.*

Format we want for community entries (cribbed from above): short, concrete, falsifiable. If your transcript can't be summarized in two minutes of reading, it's too long.

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
