---
name: ulw-status
description: Show the current ULW session state — workflow mode, domain, intent, counters, and flags. Use for debugging or inspecting what the hooks decided.
---
# ULW Status

Run the status script and display the output to the user:

```
bash ~/.claude/skills/autowork/scripts/show-status.sh
```

Display the output as-is. If the session shows issues (guard exhausted, high stall counter, missing verification), briefly note what it means.
