---
name: ulw-resume
description: Resume a /ulw task that was killed by a Claude Code rate-limit StopFailure. Atomically claims the most relevant unclaimed `resume_request.json` for the current cwd (or matching project_key) and surfaces the prior session's objective + last user prompt so /ulw can replay the work as-if-uninterrupted. Pairs with the SessionStart resume-hint hook (Wave 1) and the headless watchdog (Wave 3) — all three consume the same artifact via the canonical `claim-resume-request.sh` helper. Use when the SessionStart hint surfaces a pending resume, when a continuation prompt arrives in a session with a claimable artifact, or when the user explicitly asks to resume the prior /ulw work.
argument-hint: "[--peek | --list | --session-id <sid>]"
disable-model-invocation: false
---
# ULW Resume

Resume a `/ulw` task that the Claude Code rate-limit window interrupted, as-if-uninterrupted.

## What it does

Atomically claims the most relevant unclaimed `resume_request.json` artifact, prints the prior session's `original_objective` and verbatim `last_user_prompt`, and lets `/ulw` re-enter the original task using the same vocabulary that triggered it the first time. The claim is **single-shot** (a successful claim mutates the artifact's `resumed_at_ts` + `resume_attempts`), guarded by a cross-session lock so the SessionStart hint, the `/ulw-resume` skill, and the headless watchdog cannot all race onto the same artifact.

## Match precedence

1. `--target <path>` — explicit artifact path (highest precedence; the watchdog uses this).
2. `--session-id <sid>` — pin to a specific origin session.
3. `cwd-match` — artifact's `.cwd` equals the new session's `$PWD`.
4. `project-match` — artifact's `.project_key` matches `_omc_project_key` (worktree / clone-anywhere stable).
5. `other-cwd` fallback — most recent claimable artifact regardless of cwd.

The user can run `/ulw-resume --list` first to see all claimable artifacts before deciding.

## Steps

1. **Inspect first if uncertain.** Run with `--peek` to print the artifact contents without mutating it. Use this when more than one resume might be claimable (the SessionStart hint surfaces the count) and the user wants to verify which one will be picked.

   ```bash
   bash ~/.claude/skills/autowork/scripts/claim-resume-request.sh --peek
   ```

2. **Claim atomically.** Run without `--peek` to claim:

   ```bash
   bash ~/.claude/skills/autowork/scripts/claim-resume-request.sh
   ```

   On success the helper prints a one-line JSON object containing the pre-claim artifact contents (so you see the prior `original_objective`, `last_user_prompt`, `matcher`, and `_match_scope`). The claim writes `resumed_at_ts` and `resume_attempts: 1` atomically before stdout, so the SessionStart hint and watchdog will not re-fire on the same artifact in subsequent sessions. Exit 1 means no claimable match. Exit 2 means contention (caller should retry once after a brief delay).

3. **Replay the original prompt — read the VALUE, not the JSON envelope.** The helper emits one-line JSON. Do **not** paste this JSON back at the user. Instead:
   - Extract `.last_user_prompt` (the verbatim prompt the user originally typed). Treat **that string's value** as if the user had just typed it.
   - If the value starts with `/ulw`, `/autowork`, `/ultrawork`, or `sisyphus`, re-enter the `/ulw` skill with the rest of the prompt as the argument.
   - If `last_user_prompt` is empty, fall back to `original_objective`. The helper now refuses to claim when BOTH are empty (exits 1 with stderr diagnostic) — so you should never see an artifact with no replayable content.

   **Worked example.** Suppose claim emits:

   ```json
   {"original_objective":"Make the auto-resume harness impeccable","last_user_prompt":"/ulw continue all waves of the agent-memory wall feature. Make this impeccable.","matcher":"rate_limit","_claimed_path":"/Users/me/.claude/quality-pack/state/sess-old/resume_request.json","_match_scope":"cwd-match"}
   ```

   Your next action is to invoke `/ulw` with `continue all waves of the agent-memory wall feature. Make this impeccable.` as the argument — preserving the exhaustive-authorization marker (`Make this impeccable`) that triggers Phase 8 routing. **Forbidden**: pasting the JSON back at the user, or restating the artifact metadata as a status update and asking *"should I proceed?"*. The user already decided when they invoked `/ulw-resume`; your job is execution.

4. **Continue the work.** Apply the autowork rules to the replayed task. Specialist routing, wave-grouping, and review gates all behave as if the work were never interrupted. Phase 8 wave plans survive the resume because Wave 1's `session-start-resume-handoff.sh` extension copies `findings.json`, `gate_events.jsonl`, and `discovered_scope.jsonl` to the resumed session.

## Optional flags

- `--peek` — read-only inspection; does NOT claim.
- `--list` — print one TSV row per claimable artifact (`<scope>\t<session_id>\t<captured_at_ts>\t<path>`); does NOT claim.
- `--dismiss` — stamp `dismissed_at_ts` on the most relevant artifact so the SessionStart hint and the router directive both stop firing for it. Use when the user explicitly does NOT want to resume the prior task. The artifact remains on disk for `/ulw-report` audit; the parent state-dir TTL sweep eventually removes it. The dismiss is **single-shot** — a second `--dismiss` on the same artifact exits 1 cleanly.
- `--session-id <sid>` — pin to a specific origin session (use after `--list` to disambiguate when multiple are claimable).
- `--target <path>` — pin to an exact artifact path (the headless watchdog uses this in Wave 3; required for `--watchdog-launch` to prevent the daemon from racing across artifacts).

## When NOT to use

- The user's current prompt is unrelated to the prior task — call this out and proceed with the new prompt. The artifact will time out automatically after `OMC_RESUME_REQUEST_TTL_DAYS` (default 7d).
- The SessionStart hint flagged the artifact as `other-cwd` and the user has not confirmed they want to resume cross-project — verify intent first.
- The artifact's `.cwd` no longer exists — the resume will likely fail; tell the user before claiming.
- `stop_failure_capture` is `off` — there are no artifacts to claim (the helper exits 1 silently).

## Errors

- `exit 1` (no claimable match): no `resume_request.json` is unclaimed, or the filters excluded all candidates. Tell the user there is nothing to resume.
- `exit 2` (lock contention or atomic write failure): rare — a parallel claimer (watchdog or another session) raced. Sleep 1–2s and retry once.
