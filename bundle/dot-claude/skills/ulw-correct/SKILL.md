---
name: ulw-correct
description: Correct a misclassified ULW turn (wrong intent or domain). Records the correction to cross-session telemetry so future tuning can learn from human-labeled misfires, and updates the active session's intent/domain when a corrected value can be parsed from the reason. Use when the classifier got it wrong and you want to redirect rather than rephrase.
argument-hint: <correction reason — optionally include "intent=X" and/or "domain=Y">
---
# Correct a ULW Misclassification

Tell the harness "the last turn was misclassified" with a short reason. The classifier's `detect_classifier_misfire` is passive — it only records misfires when it sees blocks or bare-affirmation patterns in the next turn. This skill is the active counterpart: a one-button "this is wrong, here's the correction" verb so you don't have to rephrase three ways or learn the classifier's mental model.

## Usage

```text
/ulw-correct this is advisory not execution
/ulw-correct intent=advisory domain=writing — was asking what to write, not to write it
/ulw-correct domain=mixed — the docs change has a code change attached
```

## What it does

1. Records a `corrected_by_user=true` row in `classifier_telemetry.jsonl` for the current session and in `~/.claude/quality-pack/classifier_misfires.jsonl` cross-session. The row carries: prior intent/domain (what the classifier inferred), corrected intent/domain (if parseable from the reason), reason text, and the prompt that was misclassified.
2. If the correction names an `intent=X` or `domain=Y` (with X/Y matching a valid value), updates the active session's `task_intent` and/or `task_domain` state so subsequent gates and directives use the corrected routing.
3. Acknowledges with a one-line summary: what changed, what didn't.

## Steps

1. Take the user's correction reason (everything after `/ulw-correct`).
2. Invoke the recording script:

   ```bash
   bash ~/.claude/skills/autowork/scripts/ulw-correct-record.sh "REASON_HERE"
   ```

3. The script will print one of:
   - `corrected: intent <old> → <new>, domain <old> → <new>` when both parsed and updated
   - `corrected: intent <old> → <new>` or `corrected: domain <old> → <new>` when one parsed
   - `recorded as misfire (no intent= or domain= parseable from reason)` when only the reason text was captured
4. Confirm to the user, then continue the work in the corrected mode.

## When NOT to use

- A gate is blocking but you're confident the work is complete → `/ulw-skip <reason>` (gate bypass, not classification correction)
- The classifier was right and YOU want to declare a different scope → just say so in the prompt; classification is correct, scope is yours to set
- You need user input on taste/policy → `/ulw-pause <reason>` (session-handoff signal)

## Valid intent / domain values

- **intent**: `execution`, `continuation`, `advisory`, `session_management`, `checkpoint`
- **domain**: `coding`, `writing`, `research`, `operations`, `mixed`, `general`

Other values are recorded in the reason but do not update state.
