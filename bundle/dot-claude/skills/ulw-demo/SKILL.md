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
6. Receive three first-prompt suggestions tailored to your repo

## Instructions

Walk the user through a hands-on demo of the quality gates. Follow these steps exactly, and **print the bolded banner that prefaces each step verbatim** so the transcript has clear chapter markers (important for README GIF recordings).

### Step 1: Explain what's about to happen

Print this banner on its own line, then the explanation:

```
━━━ BEAT 1/7 · INTRO ━━━
```

Tell the user:
> I'm going to walk you through oh-my-claude's quality gates. You'll see me get blocked from stopping until I complete testing and review. This is exactly what happens during real `/ulw` tasks — the harness enforces quality structurally.

### Step 2: Create a demo file

Print this banner on its own line first:

```
━━━ BEAT 2/7 · EDIT (triggers the edit tracker) ━━━
```

Create a small file called `/tmp/omc-demo.sh` with a simple bash function that has a deliberate minor issue (e.g., missing quotes around a variable). Keep it under 10 lines. This triggers the edit tracker.

### Step 3: Attempt to stop (you will be blocked)

Print this banner on its own line first:

```
━━━ BEAT 3/7 · STOP-GUARD (expect [Quality gate] block) ━━━
```

After creating the file, attempt to deliver your response and stop. The stop-guard will block you with a `[Quality gate]` message. **Show the user this is happening** — add a one-line call-out like `↳ blocked: verification + review not yet run` so the GIF viewer sees what just happened.

### Step 4: Run verification

Print this banner on its own line first:

```
━━━ BEAT 4/7 · VERIFY (satisfies the verification gate) ━━━
```

Run `bash -n /tmp/omc-demo.sh` to syntax-check the file. This satisfies the verification gate.

### Step 5: Run a code review

Print this banner on its own line first:

```
━━━ BEAT 5/7 · REVIEW (satisfies the review gate) ━━━
```

Delegate to the `quality-reviewer` agent to review the demo file. Scope the review prompt tightly to keep it under 20 seconds (e.g., "Review `/tmp/omc-demo.sh` for defects. Single-file, ~10 LOC. Report under 100 words.").

### Step 6: Address any findings and stop cleanly

Print this banner on its own line first:

```
━━━ BEAT 6/7 · SHIP (all gates green) ━━━
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

### Step 8: Bridge to a real first task

Print this banner on its own line first:

```
━━━ BEAT 7/7 · NEXT (your first real task) ━━━
```

The user just felt the gates fire on a demo file. The bridge to "I tried it on my own work" is the highest-leverage next moment — without a concrete prompt to run, most users walk away here.

Quickly inspect the user's current working directory to detect the dominant project type (a single shell command — `ls` plus a glance at any obvious manifest like `package.json`, `Cargo.toml`, `pyproject.toml`, `Package.swift`, `Gemfile`, `.git`, `*.md`). Then suggest **three concrete first prompts** the user can copy-paste, tailored to what you saw. Keep each under one line:

- **Code project (Node/Python/Rust/Swift/etc.)** examples:
  - `/ulw fix the most recent failing test and add regression coverage`
  - `/ulw refactor <file you saw> to remove its largest function`
  - `/plan-hard add <a feature the README mentions but isn't implemented>`
- **Docs / writing project** examples:
  - `/ulw rewrite the introduction of <file you saw> for sharper voice`
  - `/librarian <topic referenced in the docs>` (look up authoritative external sources)
  - `/ulw turn the README's outline into a polished landing page`
- **Mixed / unclear** examples:
  - `/plan-hard <something the user might want to do>`
  - `/metis <a plan you draft for them based on what you saw>`
  - `/oracle why is <observable thing> happening?`

If the directory looks like a fresh oh-my-claude install or you can't tell the project type, fall back to:
- `/ulw audit this repo and tell me what to do first`
- `/council` (broad evaluation; will auto-trigger Phase 8 if you ask for fixes)
- `/ulw-status` (peek at session state to see how the harness is tracking your work)

Close with a single sentence: **"Pick one and run it — the harness will route the right specialists automatically."** This is the handoff that closes the post-demo cliff.

### Step 9: Clean up

Remove `/tmp/omc-demo.sh`.

## Important

- This demo MUST trigger real quality gates — do not simulate or describe them. The user needs to see the actual `[Quality gate]` block messages in their transcript.
- Keep the demo file trivial — this is about demonstrating the gates, not writing production code.
- Print the BEAT banners verbatim — they are chapter markers for README GIF recordings and must be visually distinct from regular prose.
- The whole demo should take under 2 minutes.
- `/ulw-demo` auto-activates ULW mode via the `is_ulw_trigger` helper, so the stop-guard should block on Beat 3 even on a brand-new install. If it does not, the install may be stale (`bash verify.sh` checks integrity) or the session may have been flipped off via `/ulw-off` — ask the user to verify and re-run.
