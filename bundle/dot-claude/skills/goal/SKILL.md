---
name: goal
description: Set a persistent, user-declared GOAL that the harness drives toward relentlessly across turns — re-anchoring it and blocking premature Stops until the goal is verifiably achieved (fresh completeness audit + attestation) or it hits a no-progress wall it cannot pass alone. The user-facing port of Codex CLI's /goal. Lifecycle subcommands cover set / status / pause / resume / clear / done. Use when the user wants the agent to keep working toward one durable objective instead of stopping after a normal turn.
argument-hint: <objective | pause | resume | clear | done | (empty = status)>
---
# /goal — relentless drive toward a durable objective

`/goal <objective>` declares a **persistent goal** and arms a relentless driver: at every Stop the harness re-anchors the verbatim goal and **blocks the stop** until the goal is verifiably achieved or it hits a wall it cannot pass alone. This is the user-facing, **voluntary** port of OpenAI Codex CLI's `/goal` — "keep a goal alive across turns; plan → act → test → refine; do not stop until the goal is reached."

It is the deliberate sibling of the involuntary `objective-contract` gate: that gate fires *reactively* on big-task detection and caps at 2 nudges; `/goal` is armed *on purpose* by the user and drives *relentlessly* (uncapped except for the safety escape below).

**Single-entrance embed (v1.47).** Two consequences:

- **`/goal <objective>` is itself a full ULW entrance.** The prompt-intent-router treats a set-shaped `/goal` command as a ULW activation trigger (same branch as `/ulw`), so the driver it arms is never born dormant. Lifecycle invocations (`/goal pause|resume|clear|done|status`, bare `/goal`) and prose *mentions* of /goal do **not** activate.
- **You usually don't need this command at all.** An explicit goal declaration in a plain `/ulw` prompt — *"don't stop until tests pass"*, *"your goal is …"*, *"keep going until …"*, a prompt starting *"goal: …"* — auto-arms the same driver (`goal_auto_arm=on`, default). The router announces every auto-arm; `/goal clear` stands it down. `/goal` remains the explicit handle and the home of the lifecycle verbs.

## How it drives

While a goal is active, the stop-guard reuses the objective-contract re-anchor machinery but **unconditionally** (no big-task detection needed — you armed it):

- **Block at Stop.** Each time the agent tries to stop with work done this cycle but the goal not attested complete, the Stop is blocked and the goal is re-injected verbatim, telling the agent to drive the next concrete sub-step.
- **Release only on verified completion.** The driver releases when the agent (a) runs a **fresh-context completeness audit** this cycle (dispatch `excellence-reviewer` with the goal) AND (b) attests **`**Goal achieved.**`** (or `**Objective coverage.**`) in its closing summary. Self-attestation alone does **not** clear it — the fresh audit is required, because a drifted model declaring "done" is exactly the failure this guards against.
- **Stuck-wall escape (the safety valve).** If the driver blocks `goal_stuck_threshold` times (default `3`) in a row **with no progress** (no edits between blocks), it surfaces a "stuck-wall" message to the user and **releases** — it never traps. Any real edit between blocks resets the counter, so a model genuinely grinding forward is never cut off; only spinning-in-place trips the wall. Mirrors Codex's "stops when it hits a wall it can't get past alone."

## Criteria-first close

The arming response declares more than the goal itself: it also states **numbered acceptance criteria** — a short list, 3-7 items, each derived from the objective and independently checkable. Every later goal-progress response may reference a criterion by number instead of re-deriving it.

The **`**Goal achieved.**`** attestation MUST close with a per-criterion checklist — one line per criterion: `✅`/`❌` + the criterion + concrete evidence (an exact command and its result signal, a `file:line`, or a reviewer VERDICT). `❌` lines are legitimate only on the stuck-wall release path, never alongside a self-declared attestation — a goal cannot attest achieved with any `❌` remaining.

## Usage / subcommands

The model maps the user's `/goal …` to the backing script:

```bash
bash ~/.claude/skills/autowork/scripts/goal.sh set "<objective>"   # arm the goal
bash ~/.claude/skills/autowork/scripts/goal.sh                     # status (no args)
bash ~/.claude/skills/autowork/scripts/goal.sh pause               # suspend the driver
bash ~/.claude/skills/autowork/scripts/goal.sh resume              # re-engage
bash ~/.claude/skills/autowork/scripts/goal.sh clear               # stand down + wipe
bash ~/.claude/skills/autowork/scripts/goal.sh done "<reason>"     # mark achieved + wipe
```

A bare `goal.sh "<objective>"` with no recognized verb is treated as `set` (so the verb can't be fumbled). State all five subcommands map 1:1 to the user's `/goal pause|resume|clear|done` and bare `/goal` (status).

Write a goal as a **verifiable end state** — Codex's guidance applies: "Complete X without stopping until <verifiable end state>." Good: `migrate the Python project from Pydantic v1 to v2 and make the full test suite pass`. Weak: `improve the code` (no end state to verify against).

## Steps for the model

1. Parse the user's argument. Empty → `status`; a recognized verb → that subcommand; anything else → `set "<that text>"`.
2. Run the backing script and relay its one-line confirmation.
3. On `set`, lead your next turn by re-stating the goal in one sentence and starting work — under ULW the goal IS the standing instruction; do not ask whether to begin.
4. Drive relentlessly. When you believe the goal is achieved: dispatch `excellence-reviewer` (Agent tool) with the goal for a fresh completeness audit, ship anything it surfaces, then attest **`**Goal achieved.**`** in your summary. That + the recorded audit releases the driver.

## Scope and the cross-session question

This is **session-persistent**: the goal lives in session state and persists across *turns* within a session (Codex's "keep a goal alive across turns" Ralph-loop core). It does **not** survive across separate Claude Code sessions.

That boundary is deliberate. The No-Out-of-Scope contract sanctions only `/ulw-resume` (involuntary rate-limit kill) for cross-session Stop-survival; a fresh `abstraction-critic` ruling (CHANGELOG) declined a *durable cross-session work-survival artifact* as the contract's prohibited shape. A voluntary cross-session goal artifact is a separate, contestable decision — if it is ever built it must store **only the declared objective** (an input that re-arms the driver), never a remaining-work list (a deferral backlog). Until then, `/goal` is in-session.

## When NOT to use, and the escape valves

- **Not a substitute for `/ulw`.** Plain `/ulw <task>` already drives a single objective hard within a turn. Reach for `/goal` when you want a *named, durable* objective that survives many turns and stop attempts with explicit lifecycle control.
- **`clear` / `done` are USER lifecycle commands.** Under ULW, do **not** invoke `/goal clear` or `/goal done` yourself to escape the driver. The legitimate completion path is achieve → fresh audit → attest `**Goal achieved.**`; the legitimate stuck path is the auto stuck-wall or `/ulw-pause`. Every `clear`/`done` is logged.
- **Operational blocks** (credentials, rate limit, dead infra) → `/ulw-pause <reason>` — the goal arm stands down for that turn.
- **A single quality gate is wrongly blocking and the work is genuinely complete** → `/ulw-skip <reason>` (one-shot).

## Configuration

- `goal_gate=on|off` (default `on`) — master switch for the relentless driver. With a goal set but `goal_gate=off`, the goal is remembered but the driver does not block. Env: `OMC_GOAL_GATE`.
- `goal_stuck_threshold=N` (default `3`) — consecutive no-progress blocks before the stuck-wall surfaces and releases. `0` disables the wall (fully uncapped — use with care). Env: `OMC_GOAL_STUCK_THRESHOLD`.
- `goal_auto_arm=on|off` (default `on`) — auto-arm the driver from explicit goal-declaration prose on a fresh `/ulw` execution prompt (v1.47 single-entrance embed). High-precision markers only; continuation prompts and open-mandate ambition prose never auto-arm. Env: `OMC_GOAL_AUTO_ARM`.

## Dormancy honesty (direct goal.sh calls)

The driver lives in the stop-guard, which runs only in ultrawork mode. The `/goal` *command* can no longer produce a dormant goal (it activates ULW itself), but a **direct `goal.sh` invocation** in a vanilla session still can — `set` and `status` print an explicit `DORMANT` note in that case instead of claiming the driver is active. Any `/ulw` prompt activates the session and animates the recorded goal.
