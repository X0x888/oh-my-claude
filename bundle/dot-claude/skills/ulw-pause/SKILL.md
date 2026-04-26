---
name: ulw-pause
description: Signal a legitimate user-decision pause without tripping the session-handoff gate. Use when the user must make a call you cannot make autonomously (taste, policy, credible-approach split) and continuing would require guessing. Distinct from /ulw-skip (gate bypass) and /mark-deferred (defer findings) — this announces "I'm paused, waiting for your input on X".
argument-hint: <reason>
---
# Pause for User Decision

Signal that the assistant is pausing because the user must make a decision the assistant cannot make autonomously — not because the work is hard, not because a gate is blocking, but because the next step turns on user judgment (taste, policy, brand voice, pricing, credible-approach split, etc.).

This is the affordance the user-reported gap pointed at: the session-handoff gate fires correctly on lazy stops, but it has no way to distinguish a lazy stop from a legitimate "I need your input" pause. `/ulw-pause` is that distinction.

## Usage

The user (or the assistant on the user's behalf) provides a reason: `/ulw-pause cut copy A or copy B for the empty state — this is brand voice, your call`

The reason should name the specific decision being asked for. "paused" alone is the same as a lazy stop; the gate exists to prevent that. Good reasons name *what* the user is being asked to decide and *why* it is theirs to decide rather than the assistant's.

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

- The decision is one the assistant *can* make (a refactor approach with two reasonable paths but neither is load-bearing) — pick one, state the choice briefly, proceed. `/ulw-pause` is for decisions that genuinely belong to the user.
- A gate is firing — that is a different signal. Use `/ulw-skip <reason>` once for gate bypass, or address the gate's underlying concern.
- A council finding needs user input on a specific finding — use `record-finding-list.sh mark-user-decision <id> <reason>` to flag the finding rather than pausing the whole session. The wave executor will surface that finding to the user before executing it; the session continues with the rest of the wave plan.
- The work is incomplete and you want to checkpoint the rest for a future session — that is the cross-session-handoff anti-pattern. Continue the work in this session.
