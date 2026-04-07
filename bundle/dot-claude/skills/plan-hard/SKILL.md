---
name: plan-hard
description: Build a decision-complete implementation plan before coding. Use when the task is non-trivial, risky, or ambiguous.
argument-hint: "[task]"
disable-model-invocation: true
context: fork
agent: quality-planner
---
Plan this task with maximal specificity:

$ARGUMENTS

Return:

1. Objective and constraints
2. Key facts discovered
3. Recommended approach
4. File-by-file or system-by-system plan
5. Validation steps
6. Risks, unknowns, and fallback

Do not edit files.
