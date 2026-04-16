---
name: ulw
description: Short alias for the maximum-autonomy professional workflow. Use when you want Claude Code to auto-detect the task domain and run the right specialist path.
argument-hint: "[task]"
disable-model-invocation: true
model: opus
---
# ULW

`/ulw` is a short alias for `/autowork`. The operating rules and execution style live in the autowork skill; the first-response opener and domain-specific routing are injected by the UserPromptSubmit hook at runtime. Do not restate the autowork rules or the hook-injected framing in this file.

Primary task:

$ARGUMENTS

Apply the autowork rules to the task above.
