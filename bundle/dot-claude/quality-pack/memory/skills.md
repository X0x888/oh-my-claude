# oh-my-claude Skills

- `/ulw <task>` is the main workflow. Use it for end-to-end implementation, debugging, migrations, refactors, and other non-trivial work where autonomy matters. Aliases: `/autowork`, `/ultrawork`, `sisyphus` also work.
- `/plan-hard <task>` creates a decision-complete plan without editing files.
- `/review-hard [focus]` performs a findings-first review of the current worktree or a focused area.
- `/research-hard <topic>` gathers targeted repository, tool, or API context before implementation.
- `/prometheus <goal>` runs interview-first planning for broad or ambiguous work before implementation.
- `/metis <plan or focus>` stress-tests a draft plan or current approach for hidden risks and missing constraints.
- `/oracle <issue>` provides a deep debugging or architecture second opinion when the right path is unclear.
- `/librarian <topic>` gathers official docs, external APIs, reference implementations, and concrete source material.
- `/frontend-design <task>` creates distinctive, design-first frontend interfaces. Establishes visual direction (palette, typography, spacing, layout, visual signature) before writing code. Use when visual craft matters.
- `/atlas [focus]` bootstraps or refreshes concise project-specific instruction files for the current repository.
- `/council [focus]` dispatches a multi-role project-evaluation panel (PM, design, security, data, SRE, growth). Also auto-triggers under `/ulw` when the prompt asks for a broad project assessment.
- `/ulw-demo` runs a guided onboarding walkthrough that triggers real quality gates on a demo file so new users can see the harness in action.
- `/ulw-status` shows the current ULW session state -- workflow mode, domain, counters, and flags (debugging).
- `/ulw-skip <reason>` skips the current quality gate block once with a logged reason. Use when a gate is blocking but you're confident the work is complete.
- `/ulw-off` deactivates ultrawork mode mid-session without ending the conversation.
- `/skills` lists all available skills with descriptions and a decision guide.
- The `ulw` family auto-detects whether a task is coding, writing, research, operations, mixed, or general work, then chooses the correct specialists. Specialist agents activate automatically — you don't need to learn agent names.
