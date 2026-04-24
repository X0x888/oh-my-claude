---
name: ulw-demo
description: Guided onboarding demo that shows oh-my-claude's quality gates in action. Use after first install to see how stop-guard blocking, review loops, and verification work.
argument-hint: ""
model: opus
---
# ULW Demo — See the Quality Gates in Action

This is a guided walkthrough of oh-my-claude's quality enforcement. You will:
1. Make a small code edit (triggers the edit tracker)
2. Attempt to stop (triggers the stop-guard block)
3. Run verification (satisfies the verification gate)
4. Run a review (satisfies the review gate)
5. Stop cleanly (all gates satisfied)

## Instructions

Walk the user through a hands-on demo of the quality gates. Follow these steps exactly, and **print the bolded banner that prefaces each step verbatim** so the transcript has clear chapter markers (important for README GIF recordings).

### Step 1: Explain what's about to happen

Print this banner on its own line, then the explanation:

```
━━━ BEAT 1/6 · INTRO ━━━
```

Tell the user:
> I'm going to walk you through oh-my-claude's quality gates. You'll see me get blocked from stopping until I complete testing and review. This is exactly what happens during real `/ulw` tasks — the harness enforces quality structurally.

### Step 2: Create a demo file

Print this banner on its own line first:

```
━━━ BEAT 2/6 · EDIT (triggers the edit tracker) ━━━
```

Create a small file called `/tmp/omc-demo.sh` with a simple bash function that has a deliberate minor issue (e.g., missing quotes around a variable). Keep it under 10 lines. This triggers the edit tracker.

### Step 3: Attempt to stop (you will be blocked)

Print this banner on its own line first:

```
━━━ BEAT 3/6 · STOP-GUARD (expect [Quality gate] block) ━━━
```

After creating the file, attempt to deliver your response and stop. The stop-guard will block you with a `[Quality gate]` message. **Show the user this is happening** — add a one-line call-out like `↳ blocked: verification + review not yet run` so the GIF viewer sees what just happened.

### Step 4: Run verification

Print this banner on its own line first:

```
━━━ BEAT 4/6 · VERIFY (satisfies the verification gate) ━━━
```

Run `bash -n /tmp/omc-demo.sh` to syntax-check the file. This satisfies the verification gate.

### Step 5: Run a code review

Print this banner on its own line first:

```
━━━ BEAT 5/6 · REVIEW (satisfies the review gate) ━━━
```

Delegate to the `quality-reviewer` agent to review the demo file. Scope the review prompt tightly to keep it under 20 seconds (e.g., "Review `/tmp/omc-demo.sh` for defects. Single-file, ~10 LOC. Report under 100 words.").

### Step 6: Address any findings and stop cleanly

Print this banner on its own line first:

```
━━━ BEAT 6/6 · SHIP (all gates green) ━━━
```

Fix any findings the reviewer flags, then deliver the final summary. The stop-guard should now allow you to stop. Close with a one-line recap like `✓ edit → block → verify → review → fix → ship`.

### Step 7: Explain what happened

After the demo completes, give the user a brief summary:
- **Edit tracking**: every file edit is recorded with timestamps
- **Stop-guard**: blocks completion until verification and review are done
- **Verification gate**: requires running tests/lints after code changes
- **Review gate**: requires a specialist reviewer before finalizing
- **Gate caps**: if a gate blocks 3 times, it releases (safety valve)

Then tell them: "This is what `/ulw` does on every real task. The gates fire automatically — you never need to think about them."

### Step 8: Clean up

Remove `/tmp/omc-demo.sh`.

## Important

- This demo MUST trigger real quality gates — do not simulate or describe them. The user needs to see the actual `[Quality gate]` block messages in their transcript.
- Keep the demo file trivial — this is about demonstrating the gates, not writing production code.
- Print the BEAT banners verbatim — they are chapter markers for README GIF recordings and must be visually distinct from regular prose.
- The whole demo should take under 2 minutes.
- If the stop-guard does **not** block on Beat 3, ULW mode is not active in this session. Ask the user to run `/ulw <anything>` first to flip the session into ultrawork mode, then re-run `/ulw-demo`.
