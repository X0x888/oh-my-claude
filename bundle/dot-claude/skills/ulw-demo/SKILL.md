---
name: ulw-demo
description: Guided onboarding demo that shows oh-my-claude's quality gates in action. Use after first install to see how stop-guard blocking, review loops, and verification work.
argument-hint: ""
model: opus
---
# ULW Demo — See the Quality Gates in Action

This is a guided walkthrough of oh-my-claude's quality enforcement. You will:
1. Run a tiny specialist pass before mutation (satisfies the agent-first gate)
2. Make a small code edit (triggers the edit tracker)
3. Attempt to stop (triggers the stop-guard block)
4. Run verification (satisfies the verification gate)
5. Run a review (satisfies the review gate)
6. Stop cleanly (all gates satisfied)
7. Receive three first-prompt suggestions tailored to your repo

## Instructions

Walk the user through a hands-on demo of the quality gates. Follow these steps exactly, and **print the bolded banner that prefaces each step verbatim** so the transcript has clear chapter markers (important for README GIF recordings).

### Step 1: Explain what's about to happen

Print this banner on its own line, then the explanation:

```
━━━ BEAT 1/8 · INTRO ━━━
```

Tell the user:
> This will take about 90 seconds. You don't need to type anything — just watch the gates fire on a throwaway file in `/tmp`. I'll walk you through oh-my-claude's quality gates: you'll see me get blocked from stopping until I complete testing and review. This is exactly what happens during real `/ulw` tasks — the harness enforces quality structurally.

### Step 2: Run a pre-edit specialist pass

Print this banner on its own line first:

```
━━━ BEAT 2/8 · AGENT-FIRST (fresh specialist before mutation) ━━━
```

Delegate to the `quality-planner` agent before editing. Scope the prompt tightly to keep it under 15 seconds (e.g., "Plan the tiny `/tmp/omc-demo.sh` quality-gate demo. Single bash file under 10 LOC. Return one short implementation note and one risk."). This satisfies the agent-first gate that real `/ulw` work uses before mutation.

### Step 3: Create a demo file

Print this banner on its own line first:

```
━━━ BEAT 3/8 · EDIT (triggers the edit tracker) ━━━
```

Create a small file called `/tmp/omc-demo.sh` with a simple bash function that has a deliberate minor issue (e.g., missing quotes around a variable). Keep it under 10 lines. This triggers the edit tracker.

### Step 4: Attempt to stop (you will be blocked)

Print this banner on its own line first:

```
━━━ BEAT 4/8 · STOP-GUARD (expect [Quality gate] block) ━━━
```

After creating the file, attempt to deliver your response and stop. The stop-guard will block you with a `[Quality gate]` message. **Show the user this is happening** — add a one-line call-out like `↳ blocked: verification + review not yet run` so the GIF viewer sees what just happened.

### Step 5: Run verification

Print this banner on its own line first:

```
━━━ BEAT 5/8 · VERIFY (satisfies the verification gate) ━━━
```

Run `bash -n /tmp/omc-demo.sh` to syntax-check the file. This satisfies the verification gate.

### Step 6: Run a code review

Print this banner on its own line first:

```
━━━ BEAT 6/8 · REVIEW (satisfies the review gate) ━━━
```

Delegate to the `quality-reviewer` agent to review the demo file. Scope the review prompt tightly to keep it under 20 seconds (e.g., "Review `/tmp/omc-demo.sh` for defects. Single-file, ~10 LOC. Report under 100 words.").

### Step 7: Address any findings and stop cleanly

Print this banner on its own line first:

```
━━━ BEAT 7/8 · SHIP (all gates green) ━━━
```

Fix any findings the reviewer flags, then deliver the final summary. The stop-guard should now allow you to stop. Close with a one-line recap like `✓ edit → block → verify → review → fix → ship`.

### Step 8: Explain what happened

Brief recap — keep it tight; the user just felt the gates work, so don't over-explain:

- The agent-first gate required a fresh specialist before the edit. That's what prevents main-thread-only implementation.
- The stop-guard blocked you until verification and review were done. That's what blocks every `/ulw` task.
- Each gate has a cap (3 blocks). If Claude can't satisfy one, it surfaces the gap instead of spinning forever.

Then tell them: "This is what `/ulw` does on every real task. The gates fire automatically — you never need to think about them."

### Step 9: Bridge to a real first task

Print this banner on its own line first:

```
━━━ BEAT 8/8 · NEXT (your first real task) ━━━
```

The user just felt the gates fire on a demo file. The bridge to "I tried it on my own work" is the highest-leverage next moment — without a concrete prompt to run, most users walk away here.

Inspect the user's current working directory to detect what they're ACTIVELY working on, not just the project type. The right prompts are tailored to live work the user is in the middle of, not generic boilerplate.

Run this combined inspection in one Bash call:

```bash
ls 2>/dev/null | head -20 && echo "---" \
  && (cd "$(pwd)" && git status --short 2>/dev/null | head -10) && echo "---" \
  && (cd "$(pwd)" && git log -5 --oneline 2>/dev/null) && echo "---" \
  && find . -maxdepth 3 -mtime -1 -type f \
       \( -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.tsx' \
          -o -name '*.swift' -o -name '*.rs' -o -name '*.go' -o -name '*.rb' \) \
       -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null | head -8
```

This surfaces:
- **Project shape** (the manifest / dir layout)
- **Uncommitted changes** (`git status` — what's mid-flight)
- **Recent commits** (`git log` — what they were working on yesterday)
- **Recently modified files** (`find -mtime -1` — what they touched today)

If `git status` shows uncommitted changes in specific files, lead with **`/ulw debug or finish the work-in-progress on <file>`** — that's the highest-conversion prompt because the user is already mid-task on those files. If recent commits show a feature branch or a half-finished migration, suggest the natural next step. Falling back to project-type-generic suggestions is the LAST resort, not the default.

Three concrete first prompts the user can copy-paste, tailored to what you saw. Keep each under one line:

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

### Step 10 (v1.36.0 #18): Optional bonus — see /ulw-skip recovery

If the user opted in (or if you want a complete demo), add this beat AFTER Step 7 closes the main flow and BEFORE the wrap. Otherwise skip to Step 11 cleanup.

Print this banner on its own line first:

```
━━━ BEAT 8/9 · BONUS — /ulw-skip recovery (gate fire + skip + ship) ━━━
```

Show the user how to recover when a quality gate fires on something the model already addressed. Cite a real example from the demo: "Imagine the verifier called `bash -n` but the user wants you to also run `shellcheck` — the verification gate would re-fire. `/ulw-skip` is the structured way to bypass once with a logged reason."

Demonstrate by running:

```bash
echo "Demo: /ulw-skip exists at ~/.claude/skills/ulw-skip/SKILL.md"
echo "It logs the skip with the reason for /ulw-report telemetry."
```

The point is to surface the verb, not actually fire the skip in the demo (firing it would require synthesizing a gate-block state). Tell the user: "If a real gate fires that you've already addressed, run `/ulw-skip <one-line reason>` — the skip is recorded for threshold tuning. v1.35.0+: deferral verbs `/ulw-skip` (gate bypass) and `/mark-deferred` (defer findings) and `/ulw-pause` (user-decision pause) are not interchangeable — see the decision tree at `/skills`."

### Step 10b (v1.36.0 #18): Optional bonus — exemplifying-scope gate

This beat shows the gate that catches **under-interpretation** of `/ulw` prompts. Print:

```
━━━ BEAT 9/9 · BONUS — exemplifying-scope gate (the "for instance" rule) ━━━
```

Tell the user:

> When you write `/ulw enhance the statusline, for instance adding a reset countdown`, the harness reads that as: "the example is ONE sibling from a class — the *class* is the scope, not the literal example." A senior practitioner adding the exemplified item plus its siblings (in-flight indicators, stale-data warnings, count surfaces, model-name handling) is doing what the request actually asked. Implementing only the literal example and silently dropping the class is **under-interpretation** — `record-scope-checklist.sh init` enumerates the siblings, and the stop guard blocks silent drops.

Show the verb without firing it (the demo does not include a real prompt):

```bash
echo "Exemplifying-scope helper: ~/.claude/skills/autowork/scripts/record-scope-checklist.sh"
echo "Used internally by the harness when prompts contain example markers (for instance, e.g., such as)."
```

This bonus beat exists so new users see the v1.35.0+ defenses (bare-WHY rejection, weak-defer validator, exemplifying-scope checklist) before they hit them on real work.

### Step 11: Clean up

Remove `/tmp/omc-demo.sh`.

## Important

- This demo MUST trigger real quality gates — do not simulate or describe them. The user needs to see the actual `[Quality gate]` block messages in their transcript.
- Keep the demo file trivial — this is about demonstrating the gates, not writing production code.
- Print the BEAT banners verbatim — they are chapter markers for README GIF recordings and must be visually distinct from regular prose.
- The whole demo should take under 2 minutes.
- `/ulw-demo` auto-activates ULW mode via the `is_ulw_trigger` helper, so the stop-guard should block on Beat 3 even on a brand-new install. If it does not, the install may be stale (`bash verify.sh` checks integrity) or the session may have been flipped off via `/ulw-off` — ask the user to verify and re-run.
