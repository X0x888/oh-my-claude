# Glossary — names you will see in this harness

oh-my-claude leans on a small palette of mythology and coined names because the
harness has many specialists and the names need to be memorable, distinct, and
easy to type. Each mythology name encodes a single thing the corresponding
skill or agent does. Use this page when you cannot remember which command does
what — search by what you want to do.

## Skills (slash commands)

| Name | Mnemonic | What it does |
|---|---|---|
| **`/ulw`** | "ultrawork" | The maximum-autonomy execution mode. Routes your task to the right specialists, runs quality gates, and resists stopping early. Aliases: `/autowork`, `/ultrawork`. (Legacy alias `sisyphus` still works for muscle memory but is not the headline name — the rolling-stone metaphor undersells the fact that ULW tasks finish.) |
| **`/atlas`** | the world-bearer | Bootstraps or refreshes the project's instruction files (`CLAUDE.md`, `.claude/rules/`). Atlas held up the world; this skill holds up your repo's institutional memory across sessions. |
| **`/metis`** | the cunning counselor | Pressure-tests a draft plan for hidden risks, missing constraints, weak validation. Metis was Zeus's first wife and the Titan of cunning counsel — this skill plays the role of a sharp peer challenging your plan before you commit to it. |
| **`/oracle`** | the wise consultant | Deep debugging help or architectural second opinion. Use when root cause is unclear or two credible approaches exist and choosing wrong would cost rework. |
| **`/prometheus`** | the planner | Interview-first planning for vague or product-shaped requests. Prometheus thought ahead; this skill thinks ahead too — by asking you the right questions before any code is written. |
| **`/librarian`** | the reference desk | Pulls official docs, third-party APIs, and concrete reference implementations. Use when training data may be stale and the right answer is on someone else's docs site. |
| **`/council`** | the evaluation panel | Multi-role project evaluation (PM, design, security, data, SRE, growth). Includes Phase 7 verification of the top findings and Phase 8 wave-by-wave execution when fixes are requested. Add `--deep` to escalate lenses to opus for high-stakes audits. |
| **`/plan-hard`** | "plan, but properly" | Produces a decision-complete plan without editing files. The hyphenated `-hard` suffix marks it as the rigorous variant of "make a plan". |
| **`/review-hard`** | "review, but properly" | Findings-first code review of the current branch or a focused area. Same naming convention as `plan-hard`. |
| **`/research-hard`** | "research, but properly" | Targeted repository, tool, or API context gathering before implementation. Same naming convention. |
| **`/frontend-design`** | "design first, code second" | Establishes visual direction (palette, typography, layout, signature) before writing UI code. Use when craft matters. |
| **`/ulw-demo`** | "see it work" | Guided walkthrough that triggers real quality gates on a demo file so you can feel the harness in action. Run after first install. |
| **`/ulw-status`** | "what's the harness doing?" | In-flight session state — workflow mode, domain, intent, counters, flags, Phase 8 wave-plan progress. Use for debugging. `summary` / `classifier` arguments swap modes. |
| **`/ulw-report`** | "is the harness helping?" | Cross-session digest joining `~/.claude/quality-pack/` aggregates into a markdown report. Default window is the last 7 days. |
| **`/ulw-skip`** | "let me through this once" | Skip the current quality gate block one time, with a logged reason. Use when a gate is blocking but you're confident the work is complete. |
| **`/ulw-off`** | "switch off ultrawork" | Deactivate ultrawork mode mid-session without ending the conversation. |
| **`/skills`** | "show me the skill list" | Lists all available skills with descriptions and a decision guide. |

## Agents

These are specialist sub-agents that the skills above dispatch automatically. You normally do not invoke them directly.

| Name | Mnemonic | Role |
|---|---|---|
| **`quality-planner`** | the planner | Produces decision-complete plans; called by most execution paths. |
| **`quality-reviewer`** | the line reviewer | Reviews diffs for defects, regressions, and missing tests. |
| **`excellence-reviewer`** | the fresh-eyes reviewer | Evaluates completeness, unknown unknowns, and what a senior would add. Runs after `quality-reviewer` on complex tasks. |
| **`quality-researcher`** | the context gatherer | Surfaces repo conventions, APIs, and integration points. |
| **`design-reviewer`** | the visual-craft reviewer | Catches generic AI-generated UI patterns before they ship. |
| **`editor-critic`** | the prose reviewer | Pre-finalization critique of written deliverables. |
| **`briefing-analyst`** | the synthesizer | Turns scattered research into a brief / memo / decision-ready summary. |
| **`*-lens`** | the role evaluators | `product-lens`, `design-lens`, `security-lens`, `data-lens`, `sre-lens`, `growth-lens` — one perspective each, dispatched by `/council`. |
| **`chief-of-staff`** | the assistant | Turns vague asks into a clean checklist, agenda, message, or follow-up plan. |
| **specialist developers** | the builders | `frontend-developer`, `backend-api-developer`, `fullstack-feature-builder`, `devops-infrastructure-engineer`, `test-automation-engineer`, plus the iOS family — invoked by `/ulw` when the task domain matches. |

## Internal terms

- **Quality gate** — a stop-time check the harness enforces. Fires when the deliverable is incomplete (missing tests, missing review, unverified). The bracketed prefix in a block message names the gate (`[Quality gate · 1/3]`, `[Excellence gate · 1/1]`, `[Review coverage · 1/3]`).
- **Wave** — a 5–10-finding chunk of work in a Council Phase 8 execution plan. Each wave is planned, implemented, reviewed (quality + excellence), verified, and committed before the next starts.
- **Council Phase 8** — the bridge from "council surfaced 30 findings" to "now ship them all with rigor". Activates when the prompt asks for fixes and the council found enough findings to warrant a wave plan.
- **Discovered scope** — findings that surface during execution but weren't in the original plan. Tracked in `<session>/discovered_scope.jsonl` and gated at session-stop so they don't get silently dropped.
- **Serendipity Rule** — when a verified adjacent defect is discovered on the same code path during unrelated work, fix it in-session instead of deferring. Logged via `record-serendipity.sh` and surfaced in `/ulw-report`.
- **ULW mode** — the active state created when a `/ulw`/`/autowork`/`/ultrawork` (or any `is_ulw_trigger` match like `/ulw-demo`, `/ulw-status`) prompt is detected. Activates the gate enforcement, classifier telemetry, and specialist routing.
