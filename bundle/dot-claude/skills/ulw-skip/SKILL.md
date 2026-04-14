---
name: ulw-skip
description: Skip the current quality gate block once with a logged reason. Use when a gate is blocking but you're confident the work is complete. The skip is recorded for threshold tuning.
argument-hint: <reason>
---
# Skip Current Gate

Skip the active quality gate block once. The reason is logged to cross-session data for future threshold tuning. If you make further edits after registering the skip, it is automatically invalidated.

## Usage

The user provides a reason: `/ulw-skip trivial doc fix, no test needed`

## Steps

1. Take the user's reason text (everything after `/ulw-skip`). If no reason provided, use "user override".
2. Run the registration script with the reason as the argument:

```bash
bash ~/.claude/skills/autowork/scripts/ulw-skip-register.sh "REASON_HERE"
```

3. Confirm to the user that the skip is registered and their next stop attempt will pass through.
4. Remind them that: (a) the skip reason is logged for cross-session analysis, and (b) if they make further edits, the skip will be invalidated and they'll need to re-register.
5. Continue working or attempt to stop.
