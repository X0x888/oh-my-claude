# oh-my-claude Skills

- `/autowork <task>` is the main workflow. Use it for end-to-end implementation, debugging, migrations, refactors, and other non-trivial work where autonomy matters.
- `/ulw <task>` is a short alias for `/autowork <task>`.
- `/plan-hard <task>` creates a decision-complete plan without editing files.
- `/review-hard [focus]` performs a findings-first review of the current worktree or a focused area.
- `/research-hard <topic>` gathers targeted repository, tool, or API context before implementation.
- `/prometheus <goal>` runs interview-first planning for broad or ambiguous work before implementation.
- `/metis <plan or focus>` stress-tests a draft plan or current approach for hidden risks and missing constraints.
- `/oracle <issue>` provides a deep debugging or architecture second opinion when the right path is unclear.
- `/librarian <topic>` gathers official docs, external APIs, reference implementations, and concrete source material.
- `/atlas [focus]` bootstraps or refreshes concise project-specific instruction files for the current repository.
- `/ulw-status` shows the current ULW session state -- workflow mode, domain, counters, and flags (debugging).
- `/ulw-off` deactivates ultrawork mode mid-session without ending the conversation.
- `/skills` lists all available skills with descriptions and a decision guide.
- The `ulw` family should auto-detect whether a task is coding, writing, research, operations, mixed, or general work, then choose the correct specialists instead of forcing a coding workflow onto everything.
