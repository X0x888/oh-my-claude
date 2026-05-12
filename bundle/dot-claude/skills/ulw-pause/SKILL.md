---
name: ulw-pause
description: Signal an operational pause for a missing input or hard external blocker — NOT for technical-judgment decisions (under ULW v1.40.0 the agent owns those). Use when credentials are required, a rate limit hit, infra is dead, or the next step needs user-supplied input the agent cannot fabricate. Distinct from /ulw-skip (gate bypass) and /mark-deferred (legacy soft-defer, disabled under ULW execution).
argument-hint: <reason naming a missing input or external blocker>
---
# Pause for Operational Block (v1.40.0)

Signal that the agent is pausing because of a **missing input or a hard external blocker** — not because the work is hard, not because a technical decision feels load-bearing. Under ULW (`no_defer_mode=on`), the agent owns technical judgment: library choice, refactor scope, brand-voice default, data-retention sane default, credible-approach split, naming, file structure. Those are not pause cases — the agent picks with stated reasoning and the user redirects if wrong.

The remaining legitimate pause cases are operational:

- **Credentials or external account access** — login required, API key missing, payment method needed, OAuth flow the agent cannot complete on the user's behalf.
- **Hard external blocker** — rate limit hit, paid API quota exhausted, dead build/test infrastructure, a dependency upgrade pending in a tracked external ticket the agent cannot resolve.
- **Destructive shared-state action awaiting confirmation** — force-push to main, prod database modification, deletion of files outside the agent's clear authority. (Dev branches and disposable state: just proceed.)
- **Unfamiliar in-progress state** — untracked files or unstashed local changes whose intent the agent cannot recover; risk of clobbering the user's in-flight work.

> **What this skill is NOT for (v1.40.0):** "copy A or copy B for the empty state, your call", "should we use Stripe or LemonSqueezy", "which color for the CTA". The canonical `/ulw` user is not an expert. Asking them to adjudicate a taste/policy/credible-approach split is the agent escaping responsibility, dressed as deference. Pick the sane default (GDPR-friendly, accessible-first, the sibling-of-the-codebase choice), name the alternatives you ruled out in one line, ship. The user redirects cheaply if wrong; a held-but-undecided session costs them everything.

## Usage

The user (or the agent on the user's behalf) provides a reason that names the missing input or external blocker: `/ulw-pause Stripe API key needed in STRIPE_SECRET_KEY — cannot create the test customer without it`

Good reasons name *what is needed* (the missing input) or *what is blocking* (the external object). "paused" alone is the same as a lazy stop; the gate exists to prevent that. Reasons that name a taste/policy/credible-approach decision will pass the script's syntactic check but they violate the v1.40.0 contract — the agent should have picked and shipped instead.

## Steps

1. Take the user's reason text (everything after `/ulw-pause`). If nothing was provided, refuse and ask for a specific decision-question — silent pausing is the anti-pattern this skill exists to make explicit.
2. Run the helper script with the reason as the single argument:

   ```bash
   bash ~/.claude/skills/autowork/scripts/ulw-pause.sh "REASON_HERE"
   ```

3. The script flips an `ulw_pause_active` flag in session state, increments `ulw_pause_count`, records a `ulw-pause` gate event, and prints a one-line confirmation. Relay that to the user.
4. After the script returns, write a clean summary that surfaces the question being asked, names the options if relevant, and explicitly invites the user to weigh in. Then stop. The session-handoff gate respects the active pause state for this turn — your stop will not be re-blocked as a lazy session-handoff.
5. The next user prompt clears the `ulw_pause_active` flag automatically; the session-handoff gate returns to normal behavior on subsequent stops.

## Cap and audit

- Cap is 2 pauses per session (matches the session-handoff gate's block cap). After the cap, the gate falls back to its normal behavior — at that point a stop is structurally a session-handoff, not a pause, and you should either resume work or ask the user whether to checkpoint.
- Each invocation writes a `ulw-pause` row to `gate_events.jsonl` with the reason, so `/ulw-report` can audit pause patterns later. Repeated pauses on the same kind of decision are signal: maybe the harness should learn to handle that class of decision differently.

## When NOT to use

- **The decision is technical, not operational.** Library choice, refactor scope, brand-voice default, credible-approach split, test framework, naming, file structure, data-retention sane default — the agent owns these under ULW. Pick one with stated reasoning, ship. The v1.40.0 contract removed "product-taste or policy judgment" and "credible-approach split" from the pause-case list. If the prompt arrived without a brand-voice spec, the agent picks the sibling-of-codebase choice and ships; it does not pause to ask the non-expert user.
- **A gate is firing** — that is a different signal. Use `/ulw-skip <reason>` once for gate bypass, or address the gate's underlying concern.
- **A finding marked deferred** — under ULW execution, `record-finding-list.sh status <id> deferred` is refused. Ship the finding inline, wave-append it, or — only when it is genuinely not-a-defect — mark it `rejected` with a concrete WHY.
- **The work is incomplete and you want to checkpoint the rest for a future session** — that is the cross-session-handoff anti-pattern. Continue the work in this session.
