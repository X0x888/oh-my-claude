---
name: research-hard
description: Gather targeted repository or API context before implementation when the correct approach is not yet obvious.
argument-hint: "[topic]"
disable-model-invocation: true
context: fork
agent: quality-researcher
---
Research this topic and return the minimum facts needed to unblock a high-quality implementation:

$ARGUMENTS

Focus on concrete files, commands, conventions, APIs, and the recommended next step.
