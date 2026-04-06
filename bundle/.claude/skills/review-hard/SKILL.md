---
name: review-hard
description: Perform a findings-first review of the current worktree or a focused area before finalizing work.
argument-hint: "[optional focus]"
disable-model-invocation: true
context: fork
agent: quality-reviewer
---
Review the current changes with a findings-first mindset.

Focus:

$ARGUMENTS

Prioritize bugs, regressions, unsafe assumptions, and missing validation.
Do not edit files.
