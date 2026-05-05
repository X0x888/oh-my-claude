# ULW Version Assessment

Date: 2026-05-05

Scope:
- audited release history from `v1.0.0` through `v1.32.15`
- used `CHANGELOG.md`, release-tag commit messages, current tree counts, and targeted code inspection
- evaluated with the corrected lens: the quality of the real work a serious `/ulw` user receives first, how automatically the harness gets there second, and speed/token cost third

## Lens Correction

This is not mainly a repo-beauty contest. A version ranks higher only if it helps a Claude Code user ship better real work with less steering:

- fewer silent scope drops
- better specialist choice
- stronger review / verification before stop
- fewer avoidable user pauses
- lower latency and token drag for the same or better outcome

Internal cleanup, docs quality, and release discipline matter only when they change that user outcome or the user's ability to trust the workflow under real work.

## Second-Pass Code Audit Coverage

This revision goes beyond changelog reading.

- Full current reads:
  - `bundle/dot-claude/skills/autowork/SKILL.md`
  - `bundle/dot-claude/agents/{quality-planner,quality-reviewer,metis,release-reviewer,divergent-framer}.md`
  - `bundle/dot-claude/skills/diverge/SKILL.md`
  - `tests/{test-show-report,test-show-status,test-timing,test-directive-instrumentation}.sh`
- Direct code-diff inspection across major boundaries:
  - `prompt-intent-router.sh`
  - `pretool-intent-guard.sh`
  - `stop-guard.sh`
  - `common.sh`
  - `lib/{classifier,timing,state-io}.sh`
  - `show-{report,status}.sh`
  - `config/settings.patch.json`
- Historical boundaries inspected directly:
  - `v1.23.1 → v1.27.0`
  - `v1.27.0 → v1.28.1`
  - `v1.28.1 → v1.29.0`
  - `v1.29.0 → v1.31.3`
  - `v1.31.3 → v1.32.15`

I still did **not** literally read every file revision in every tag. This is a code-first audit of the ULW-critical surfaces.

## Executive Verdict

- **Best version for serious `/ulw` users to run today:** `v1.32.15`, but only by a narrow margin
- **Best pure ULW workflow line for user-visible work quality and automation:** `v1.31.3`
- **Best speed-focused milestone:** `v1.27.0`
- **Best scope-protection milestone:** `v1.23.1`
- **Is the latest the best?** Yes if the question is "what should a serious user run today?" No if the question is "which line contributed the biggest direct improvement to actual ULW work quality and automation?" That answer is `v1.31.3`, with `v1.27.0` the sharpest speed/value jump.
- **Were there failures?** Yes, but mostly integration failures and drift, not wrong product direction:
  - `v1.24.0`-`v1.25.0` shipped stop-hook output through an unsupported field, so time-card / scorecard epilogues were largely invisible until `v1.26.0`.
  - `v1.32.6`-`v1.32.10` shipped multi-project telemetry in stages; `project_key` existed in reads before writes, so `/ulw-report` slicing was partially a feature in name only until the follow-up closures.
  - `v1.32.x` added per-directive prompt-cost telemetry (`directive_emitted` rows) but, as shipped, did not surface that cost back to the user in `/ulw-report` or `/ulw-status`. That made the latest line stronger on instrumentation than on user-visible speed/token control until this branch closed the loop.
  - `v1.31.1` through `v1.32.15` showed release-process churn: repeated CI-red tags, cap bumps, and multiple post-tag fixes.
  - documentation and release-history drift accumulated: stale count claims and a missing `v1.16.0` changelog heading.

## Second-Pass Corrections

The code-level reread changed two parts of the first-pass assessment:

1. **`v1.32.x` has more direct ULW user value than I first credited.**
   - The `divergence_directive` is a real user-facing workflow upgrade, not release-only plumbing.
   - The router now records per-directive prompt cost, which is the right foundation for speed/token self-audit.
   - That means `v1.32.x` is not just recovery; it does contain meaningful workflow evolution.

2. **`v1.32.x` also had a real incomplete-payoff gap.**
   - The directive-cost telemetry was captured in timing rows and tested for existence, but not rendered to the user.
   - That is exactly the kind of "good feature, incomplete landing" drift pattern this project has shown before.
   - This branch now fixes that by surfacing router directive footprint in both `/ulw-report` and `/ulw-status`.

## What Improved Across The Whole Arc

The release history is not random. It moves through five clear phases:

1. **Foundation (`v1.0`-`v1.6`)**
   - built the harness skeleton: intent routing, hard gates, specialist agents, installer, statusline
   - quality improved quickly, but automation was still structural rather than semantically smart

2. **Reliability and visibility (`v1.7`-`v1.14`)**
   - stronger classifier, compaction continuity, replayable telemetry, `/ulw-report`, universal verdict contract
   - this is where ULW stopped being just opinionated and became inspectable

3. **Semantic quality and UX (`v1.15`-`v1.23`)**
   - design contracts, archetype memory, user-decision pauses, bias-defense, exhaustive-wave authorization, exemplifying-scope hard gate
   - this is the first period where ULW starts defending against "technically competent but semantically wrong"

4. **Speed, self-audit, and breadth (`v1.24`-`v1.28`)**
   - time accounting, config UX, canary for unverified claims, bulk state reads, latency budgets, intent broadening, FINDINGS_JSON
   - strongest direct work on your two priorities together: quality automation plus efficiency

5. **Evaluation maturity and release-discipline recovery (`v1.29`-`v1.32`)**
   - deep multi-lens self-evaluation, privacy controls, performance detachment, divergence framing, current-session welcome, release hardening, telemetry repair
   - biggest ambition, but also the period with the most process churn and drift debt

## Representative Growth

These counts use the latest tag inside each version line.

| Representative tag | Agents | Skills | Bash tests | Python tests |
|---|---:|---:|---:|---:|
| `v1.0.0` | 22 | 12 | 0 | 0 |
| `v1.1.0` | 23 | 13 | 7 | 1 |
| `v1.3.0` | 29 | 14 | 8 | 1 |
| `v1.11.0` | 30 | 17 | 14 | 1 |
| `v1.19.0` | 32 | 20 | 35 | 1 |
| `v1.23.1` | 32 | 23 | 47 | 1 |
| `v1.27.0` | 32 | 24 | 51 | 1 |
| `v1.31.3` | 33 | 25 | 58 | 1 |
| `v1.32.15` | 34 | 25 | 69 | 1 |

Interpretation:
- quality ambition kept expanding
- observability and test coverage scaled with it
- the main risk is no longer feature absence; it is integration complexity and release discipline

## Version-Line Assessment

Method:
- each row evaluates the **line**, using the latest patch in that line as the representative artifact
- `Q/A delta` means the quality of the delivered work a `/ulw` user is likely to get, plus how automatically the harness gets there without babysitting
- `Speed/token delta` means practical effect on latency, overhead, or prompt/tool efficiency during real work

### Foundation: `v1.0` to `v1.6`

| Line | Representative | Q/A delta | Speed/token delta | Assessment |
|---|---|---|---|---|
| `v1.0` | `v1.0.0` | Medium | Medium | Strong base: hard gates, routing, compaction continuity. Not yet enough evidence, telemetry, or tuning. |
| `v1.1` | `v1.1.0` | High | Medium | Huge practical jump: installer, statusline, excellence gate, `/ulw-status`, CI tests. First usable serious version. |
| `v1.2` | `v1.2.3` | High | Low | Prescribed reviewer sequence and compaction hardening were important, but turn cost increased and semantics were still rigid. |
| `v1.3` | `v1.3.1` | High | Medium | Council was a major quality multiplier; session safety and onboarding improved. Big upgrade for broad project evaluation. |
| `v1.4` | `v1.4.2` | High | Medium | Cross-session metrics, defect learning, verification confidence, scorecards. ULW became measurably self-aware. |
| `v1.5` | `v1.5.0` | High | Medium | Added `/ulw-skip`, per-project config, better verification confidence. Good quality tooling, still more structural than semantic. |
| `v1.6` | `v1.6.0` | Medium | Medium | MCP/browser verification support mattered for UI work. Useful, but not a major workflow-shape change. |

### Reliability and Visibility: `v1.7` to `v1.14`

| Line | Representative | Q/A delta | Speed/token delta | Assessment |
|---|---|---|---|---|
| `v1.7` | `v1.7.1` | High | Medium | Classifier hardening, autonomy rules, canonical auto-memory. Strong reliability release. |
| `v1.8` | `v1.8.1` | Medium | Medium | Better install drift detection and status visibility. More operator confidence than workflow intelligence. |
| `v1.9` | `v1.9.2` | Medium | Medium | Lock hardening, anomaly logging, repro bundle, classifier telemetry. Good supportability release. |
| `v1.10` | `v1.10.2` | High | Low | Discovered-scope gate and council depth closed silent-skip patterns. Quality up, cost and complexity also up. |
| `v1.11` | `v1.11.1` | Very High | Low | Phase 8 was one of the most important automation upgrades in the project: council findings could now turn into structured execution. |
| `v1.12` | `v1.12.0` | Medium | Medium | Architecture extract and telemetry close-out. Good debt reduction, not a user-facing breakthrough. |
| `v1.13` | `v1.13.0` | High | Medium | `/ulw-report` and visibility surfaces made the harness legible to the human. Important for trust and tuning. |
| `v1.14` | `v1.14.0` | High | Medium | Universal VERDICT and verification-lib extract made automation cleaner and more parseable. Quietly foundational. |

### Semantic Quality and UX: `v1.15` to `v1.23`

| Line | Representative | Q/A delta | Speed/token delta | Assessment |
|---|---|---|---|---|
| `v1.15` | `v1.15.0` | High | Low | Design contract expansion was a real quality win for UI work, but it increased prompt surface and token cost. |
| `v1.16` | `v1.16.0` | High | Medium | Closed the inline-contract drift gap and added cross-session archetype memory. Strong follow-through release. |
| `v1.17` | `v1.17.0` | Medium | Medium | Signal and ergonomics polish. Useful, but mostly refinement. |
| `v1.18` | `v1.18.1` | High | Medium | Workflow coherence, project maturity prior, `/ulw-pause`, user-decision annotation. Strong operator UX release. |
| `v1.19` | `v1.19.0` | High | Low | First real bias-defense layer. Semantically important, but default-off and still partially undiscoverable at this stage. |
| `v1.20` | `v1.20.0` | Medium | Medium | Memory hygiene and onboarding cleanup reduced future prompt noise and drift. Good debt reduction. |
| `v1.21` | `v1.21.0` | High | Medium | Closed the "single yes reauthorizes commit" anti-pattern and widened engineering specialist routing. Important safety fix. |
| `v1.22` | `v1.22.0` | High | Medium | Exhaustive-wave authorization and wave-shape enforcement materially improved serious multi-wave automation. |
| `v1.23` | `v1.23.1` | Very High | Medium | One of the strongest lines in the whole project: prompt-text trust, exemplifying scope, strict deferral reasons, hard scope gate. |

### Speed, Self-Audit, and Breadth: `v1.24` to `v1.28`

| Line | Representative | Q/A delta | Speed/token delta | Assessment |
|---|---|---|---|---|
| `v1.24` | `v1.24.0` | Medium | High | Time tracking and declare-and-proceed were right ideas, but stop-hook delivery was partially broken. Mixed release. |
| `v1.25` | `v1.25.0` | Medium | Medium | Better time-card UX, still built on the same stop-hook delivery bug. Nice design, flawed landing. |
| `v1.26` | `v1.26.0` | High | Medium | Broad completeness directive, model-drift canary, `/omc-config`, and stop-hook schema fix. This repaired earlier UX invisibility. |
| `v1.27` | `v1.27.0` | Very High | Very High | Best direct answer to your priorities: smarter routing, faster hot paths, better specialist prompts, stronger visibility. |
| `v1.28` | `v1.28.1` | Very High | High | Intent broadening, FINDINGS_JSON, latency budgets, generic agent rewrites. Strong system-level quality release, plus Linux portability cleanup. |

### Evaluation Maturity and Release Discipline: `v1.29` to `v1.32`

| Line | Representative | Q/A delta | Speed/token delta | Assessment |
|---|---|---|---|---|
| `v1.29` | `v1.29.0` | High | High | Deep self-audit plus privacy controls, background blindspot scan, faster timing emission. Big system maturation step. |
| `v1.30` | `v1.30.0` | High | Medium | Welcome banner, stop-output primitives, update-path summary, lock unification. More trust and resilience than raw new capability. |
| `v1.31` | `v1.31.3` | Very High | Medium | The strongest core ULW line: nine-lens evaluation, major finding closure, divergence framing, and deep workflow refinement. |
| `v1.32` | `v1.32.15` | High | Medium | Narrow current winner for users to run today. Second-pass code read confirms it adds real workflow value (`divergence_directive`, directive-cost telemetry), but also shipped one more incomplete observability loop than the first pass caught. |

## User-Facing Ranking

If the question is "which versions most improve the quality of the real work users get from `/ulw`?", my ranking is:

1. `v1.32.15` — best version to run today, but by a narrow margin
2. `v1.31.3` — best pure ULW workflow line and the clearest local maximum for direct user-visible work quality
3. `v1.29.0` — major maturity step for clarity, privacy, and hot-path speed without weakening the workflow
4. `v1.28.1` — strong quality parser + latency-budget + structured-findings line
5. `v1.27.0` — biggest single speed/smartness jump
6. `v1.23.1` — first version I would trust not to silently collapse example-shaped scope

## Which Version Works Best?

### 1. Best version for users to run today: `v1.32.15`

Why:
- the user still gets every major workflow win from `v1.23.1`, `v1.27.0`, `v1.28.1`, `v1.29.0`, and `v1.31.3`
- `v1.32.x` adds some real user-facing automation and trust improvements, but more importantly it removes ways the harness can quietly misreport, drift, or under-validate itself
- for a serious current user, "best to run now" includes confidence that the workflow will stay coherent under long, messy, real work

Why this is only a narrow win:
- much of `v1.32.x` is recovery work for earlier churn, not a fresh leap in delivered-work quality
- most of the substantive user-visible ULW behavior was already present by `v1.31.3`
- if you judge only "new ULW user value per unit of complexity", `v1.31.3` is cleaner
- as shipped, `v1.32.15` still left directive-cost telemetry invisible to the user, which mattered on the speed/token axis until this branch fixed it

### 2. Best pure ULW workflow line: `v1.31.3`

Why:
- it is the fullest expression of ULW as a serious end-to-end workflow for user work, not just harness mechanics
- the energy is still on improving what the user gets back from `/ulw`: broader evaluation, better framing, better closure, better share/report surfaces
- it feels like the local maximum before `v1.32.x` shifts a large share of effort into release-system hardening

### 3. Biggest speed/value release: `v1.27.0`

Why:
- it directly attacked the exact complaint set: slow, not smart, unsatisfying
- unlike some earlier speed work, it paired performance changes with intelligence changes
- it improved both perception and substance: routing, prompt quality, status visibility, hot-path latency

### 4. First version that truly protected user scope: `v1.23.1`

Why:
- it is where `/ulw` stopped trusting the literal example and started defending the user's likely intent class
- the exemplifying-scope hard gate addresses one of the most damaging real-world failure modes: shipping only the named example and silently dropping siblings
- later versions build on this, but `v1.23.1` is the first line where I would say the workflow became materially harder to "look competent while missing the job"

## Is The Latest Version The Best?

**For a user deciding what to run today: yes. For a historian asking where the biggest improvement to actual `/ulw` work happened: no.**

The latest version is the one I would install for real work today because:
- it preserves the important speed work from `v1.27` and `v1.29`
- it preserves the semantic-quality work from `v1.23`, `v1.28`, and `v1.31`
- it adds enough trust and closure around the workflow that the user is less exposed to harness drift

But the latest version is **not** the line that most improved the user's actual work output because:
- `v1.32.x` spends a lot of energy cleaning up release mechanics and telemetry closure
- many of the biggest direct wins to work quality, automation, and speed had already landed earlier
- the margin over `v1.31.3` is real but small

## What Failed Or Underperformed

### 1. Stop-hook delivery design (`v1.24`-`v1.25`)

This is the clearest "feature looked shipped but mostly was not felt" failure.

- the time-card and scorecard idea was good
- the implementation used a Stop-hook field Claude Code does not render
- result: the user value was largely invisible until `v1.26.0`

Verdict:
- **feature idea:** good
- **first implementation:** failure
- **final outcome:** recovered

### 2. Multi-project report slicing (`v1.32.6`-`v1.32.10`)

This is the clearest "feature in name only for a while" failure.

- reads existed before writes
- writes existed before all call sites
- historical backfill landed later
- bootstrap interaction with stamped rows surfaced later still

Verdict:
- good design direction
- incomplete first shipping discipline

### 3. Release mechanics from `v1.31.1` onward

This is the clearest process failure.

- multiple CI-red or post-tag-fix releases
- repeated cap-bump churn
- hotfix-sweep and release automation had to be invented reactively

Verdict:
- not a failure of the ULW idea
- definitely a failure of release-system maturity

### 4. Documentation and history governance

This branch found two concrete issues immediately:
- stale live counts in docs
- missing `v1.16.0` changelog heading despite a real tag

Verdict:
- low user-facing blast radius
- high maintainability signal, because it means history cannot be trusted blindly

## What Was Not A Failure

Several features were expensive or noisy, but not failures:

- **Project Council**: high token cost, but one of the strongest quality multipliers in the repo
- **Design Contracts**: heavier than baseline coding flows, but justified for UI work and became much better once inline drift was captured
- **Bias-defense directives**: sometimes chatty, but directionally correct; the later declare-and-proceed framing was the right refinement
- **Time tracking**: valuable once delivery channel and rendering were fixed

## What Could Have Been Designed Better

### 1. Directive governance should have become a registry earlier

By `v1.28`-`v1.31`, the system had multiple directive families:
- narrowing
- broadening
- exemplifying
- divergence
- planner hints
- council/Phase 8 hints

The repo repeatedly compensated with prose discipline and ad hoc mutual exclusion. A central directive registry with:
- priority
- token budget
- mutual-exclusion rules
- "informational vs blocking" class

would have reduced drift and prompt bloat earlier.

### 2. Every telemetry feature should have shipped only with full closure

A recurring pattern shows up:
- write path first
- read path later
- visible surface later
- report integration later
- historical backfill later

That happened in different forms for:
- time cards
- canary visibility
- project_key slicing
- archetype memory analytics

Better rule:
- no telemetry feature counts as shipped until it has **write + read + visible surface + regression test**

### 3. Release discipline arrived too late

The repo needed `hotfix-sweep`, `release.sh`, and stronger post-tag CI gates earlier.

The lesson is simple:
- this harness is now complex enough that release safety is part of product quality
- for ULW, release engineering is not back-office work; it is part of trust

### 4. `common.sh` stayed central for too long

The extraction work was good:
- `state-io`
- `classifier`
- `verification`
- `timing`
- `canary`

But it mostly happened after the file had already become a coordination bottleneck. The project eventually corrected course, but later than ideal.

### 5. Speed work should have been budgeted continuously, not reactively

The best speed releases (`v1.27`, `v1.29`) happened after explicit complaints or audits.

The right standing discipline is:
- latency budgets from the start
- always-on hot-path measurement
- prompt/token budget review for new directives

The project mostly reached that state by `v1.28+`, but it was learned the hard way.

## Best Features

If I rank by long-term value to ULW:

1. **Phase 8 council-to-execution bridge** (`v1.11`)
2. **Prompt-text trust + exemplifying-scope hard gate** (`v1.23`-`v1.23.1`)
3. **Speed + smartness pass** (`v1.27`)
4. **Intent broadening + FINDINGS_JSON + latency budgets** (`v1.28`)
5. **Deep self-audit and privacy/perf maturity** (`v1.29`)
6. **Nine-lens ULW evaluation and closure wave** (`v1.31`)

## Weakest Features Or Feature Lines

Ranked by how much they underdelivered relative to their apparent promise:

1. **Stop-hook epilogue delivery pre-`v1.26.0`**
2. **Project-key telemetry before `v1.32.10`**
3. **Release-process manual chain before `v1.32.14` / `v1.32.15`**
4. **Documentation/history governance before this branch's fixes**

## Recommendation

If the question is "which version should a serious user run today?", the answer is:

- **ship and use `v1.32.15`**

If the question is "which version most improved the actual work quality and automation users get from `/ulw`?", the answer is:

- **`v1.31.3`**

If the question is "which release most convincingly improved the two priorities you named?", the answer is:

- **`v1.27.0`**

## Implemented Follow-Ups In This Branch

This assessment found and fixed immediate governance debt:

1. restored the missing `v1.16.0` changelog heading
2. corrected live doc-count drift across `README.md`, `AGENTS.md`, and `CLAUDE.md`
3. extended `tests/test-coordination-rules.sh` to enforce:
   - repo-count lockstep
   - release-tag to changelog parity
4. updated CI checkout depth so tag-aware history checks run in automation

Second pass added one more real workflow improvement:

5. surfaced router directive footprint in `/ulw-report` and `/ulw-status` by wiring `directive_emitted` timing rows through the timing aggregate, report renderer, and live status timing line, so the latest line now exposes prompt-surface cost instead of merely recording it

These are not cosmetic. They directly reduce the chance that future version assessments are built on untrustworthy release history.
