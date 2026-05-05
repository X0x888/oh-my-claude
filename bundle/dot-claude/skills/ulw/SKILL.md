---
name: ulw
description: Canonical user-facing name for the maximum-autonomy professional workflow (v1.31.0 naming consolidation). Use when you want Claude Code to auto-detect the task domain and run the right specialist path. Legacy aliases `/autowork`, `/ultrawork`, `sisyphus` remain wired for muscle memory.
argument-hint: "[task]"
disable-model-invocation: true
model: opus
---
# ULW

`/ulw` is the canonical user-facing name for the maximum-autonomy professional workflow (v1.31.0 naming consolidation). The operating rules and execution style live in the `autowork` skill body; the first-response opener and domain-specific routing are injected by the UserPromptSubmit hook at runtime. Legacy aliases `/autowork`, `/ultrawork`, and `sisyphus` remain wired in the classifier for muscle-memory continuity but new prompts and docs should lead with `/ulw`. Do not restate the autowork rules or the hook-injected framing in this file.

Primary task:

$ARGUMENTS

Apply the autowork rules to the task above.
