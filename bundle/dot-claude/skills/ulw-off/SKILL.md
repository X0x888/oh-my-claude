---
name: ulw-off
description: Deactivate ultrawork mode for the addressed session. Clears its workflow and enforcement state without affecting concurrent Claude sessions.
---
# Deactivate Ultrawork

Run the deactivation script:

```
bash ~/.claude/skills/autowork/scripts/ulw-deactivate.sh "${CLAUDE_SESSION_ID}"
```

The session-id argument is required: never select a session by newest mtime.

After running:
1. Confirm to the user that ultrawork mode has been deactivated.
2. Note that quality gates (stop guard, advisory guard, etc.) will no longer fire.
3. The session continues normally — this does not end the conversation.
