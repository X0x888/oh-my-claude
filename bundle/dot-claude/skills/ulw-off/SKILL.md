---
name: ulw-off
description: Deactivate ultrawork mode mid-session. Clears the workflow state and removes the ULW sentinel so quality gates and domain routing stop firing.
---
# Deactivate Ultrawork

Run the deactivation script:

```
bash ~/.claude/skills/autowork/scripts/ulw-deactivate.sh
```

After running:
1. Confirm to the user that ultrawork mode has been deactivated.
2. Note that quality gates (stop guard, advisory guard, etc.) will no longer fire.
3. The session continues normally — this does not end the conversation.
