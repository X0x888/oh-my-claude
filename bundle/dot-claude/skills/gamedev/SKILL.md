---
name: gamedev
description: Reviews and guides game development code for Unity (C#), Godot (GDScript/C#), and web engines (Phaser, Babylon, PixiJS, Three.js) — engine-idiomatic patterns, frame-budget performance, and a run-screenshot-evaluate-fix verification loop. Use when reading, writing, or reviewing game code, game logic, shaders, ECS systems, scene trees, update loops, or game-engine projects.
---

Guide and review game-development work so it is engine-idiomatic, hits its frame budget, and is verified against the **running game**, not just a clean compile. Report genuine problems — do not nitpick or invent issues.

The defining failure mode of game code is visual or behavioral (clipping, wrong scale, missing assets, jitter, dropped frames), not compile-time. A build that succeeds tells you almost nothing about whether the game *works*. Everything below exists to close that gap.

## Engine routing — load only what's relevant (token discipline)

Read the ONE reference file for the engine in play, not all of them — the same partial-load discipline `swiftui-pro` uses:

- **Unity (C#)** → `references/unity.md`
- **Godot (GDScript or C#)** → `references/godot.md`
- **Web / HTML5 (Phaser, Babylon.js, PixiJS, Three.js)** → `references/web.md`
- **Bevy (Rust) or another native engine** → no reference file; apply the cross-engine principles below and verify API specifics against current docs.

## The frame-grounded verification loop (the core technique)

When the work renders or runs, verify against the rendered/running state — never declare game work done from source alone:

1. Plan → implement.
2. **Run** the engine (or recommend the companion MCP below so the agent can).
3. **Capture** frames / screenshots / debug output.
4. **Evaluate visible defects**: clipping, off-scale sprites/meshes, missing or pink/error assets, wrong animation state, physics jitter, z-fighting, frame drops.
5. **Fix what looks wrong**, then loop.

This is the game embodiment of the harness's verification-over-abstraction rule. When you cannot run the game (no engine, no MCP), do not claim it works — end with a `User-must-verify-UI: <scene or flow>` follow-up line naming exactly what a human must check on screen.

## Recommended companion MCPs (optional, per engine)

Surface these when the agent needs to *see and run* the game rather than reason about source — not hard dependencies:

- **Unity** — [CoplayDev/unity-mcp](https://github.com/CoplayDev/unity-mcp) (MIT): Editor introspection + control, Roslyn compile-check before run, test running, scene/GameObject manipulation. The strongest "close the loop" option for Unity.
- **Godot** — [Coding-Solo/godot-mcp](https://github.com/Coding-Solo/godot-mcp) (MIT): launch the editor, run projects in debug, capture console + error output. Note: **debug output only, no screenshots** — pair it with an explicit screenshot step (engine screenshot API or OS capture) for the visual-evaluate stage.
- **Greenfield generation across Godot / Bevy / Babylon** — [godogen](https://github.com/htdt/godogen) (MIT, supports `--agent claude`): runs the frame-grounded loop above end-to-end (generate → run → screenshot → evaluate → fix). Study it as the reference workflow.

For engine API specifics (exact node names, method signatures, package versions), **verify against current docs** via the `librarian` agent or `context7` MCP — engine APIs drift hard across major versions, so do not rely on training memory.

## Cross-engine principles (apply regardless of engine)

- **Name the frame budget and profile against it.** 60fps = 16.6ms/frame; 120fps = 8.3ms. A feature is not done until it fits the budget on the target device, measured — not assumed.
- **Pool frequently spawned objects** (bullets, particles, enemies, projectiles). Instantiate-and-destroy every frame churns the GC/allocator and causes hitches. Pre-allocate, reuse, recycle.
- **Fixed timestep for physics and gameplay simulation**, decoupled from render framerate; multiply all movement by delta-time so behavior is frame-rate independent.
- **Update-loop hygiene**: no per-frame heap allocations, no per-frame find/lookup-by-name/`GetComponent`-in-`Update`; cache references once. The hot loop is where frame budget dies.
- **Explicit state machines** for entity/scene/UI state, not boolean soup (`isJumping && !isDead && canMove`).
- **Cut draw calls**: atlas textures, batch/instance static geometry, share materials. Draw-call count is the most common silent perf killer.
- **Stream and budget assets**: load large assets async, set texture-memory budgets, unload what's off-screen. Out-of-memory on lower-end targets is a shipping defect, not an edge case.
- **Determinism** where multiplayer, replays, or rollback need it — same inputs must produce same state.
- **Decouple input from simulation**: buffer/queue input, do not poll-and-drop; consume it in the fixed-step update.

## Review process

1. Identify the engine → load its reference file.
2. Scan every per-frame update/`tick`/`_process` for allocations and lookups.
3. Check object spawning for pooling.
4. Check physics/movement for fixed-timestep + delta-time.
5. Check the frame budget against the stated target device.
6. Check engine-idiomatic structure (scene tree + signals for Godot; components + events for Unity; ECS where used).
7. Verify against a running frame whenever possible (frame-grounded loop above).

## Output format

Organize findings by file. For each issue: state the file and line(s), name the rule violated, and show a brief before/after fix. Skip files with no issues. End with a prioritized summary — the highest-impact fixes (usually frame-budget and update-loop allocations) first.
