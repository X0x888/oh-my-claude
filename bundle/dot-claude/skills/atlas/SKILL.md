---
name: atlas
description: Bootstrap or refresh concise repo-specific instruction files for the current project so future Claude sessions follow the codebase's real conventions.
argument-hint: "[optional focus]"
disable-model-invocation: true
context: fork
agent: atlas
---
Inspect the current repository and create or refresh concise Claude instruction files.

Focus:

$ARGUMENTS
