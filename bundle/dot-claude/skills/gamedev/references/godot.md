# Godot (GDScript / C#) reference

Patterns and pitfalls that survive across Godot 4.x. Godot 3 → 4 changed a large amount of API (node names, signal syntax, `KinematicBody` → `CharacterBody`, etc.) — verify the exact API against the project's Godot version's docs (via the `librarian` agent or `context7` MCP) rather than from memory.

## Scene tree & decoupling

- Decouple with **signals**, not hard-coded `get_node("../../Manager")` paths threaded everywhere. Emit signals up, call down; use `@export` to wire references in the editor.
- Cache node lookups with **`@onready var node := $Path`** once — never call `get_node()`/`$Path` every frame.
- Use **node groups** (`add_to_group` / `get_tree().call_group`) for batch operations across many nodes.

## Timing

- Gameplay/physics in **`_physics_process(delta)`** (fixed step); per-frame visual/input work in **`_process(delta)`**. Multiply movement by `delta` in both.
- `CharacterBody2D/3D`: use `move_and_slide()` with `velocity`, not manual position writes.

## Performance

- **Statically type GDScript** (`var hp: int = 100`, typed func args/returns). Typed code is meaningfully faster and catches errors at parse time.
- **Pool** bullets/particles/enemies — reuse via `visible`/`set_physics_process(false)` toggling rather than `queue_free()` + re-`instantiate()` in the hot path.
- Use **`MultiMeshInstance2D/3D`** for many identical instances and **`TileMap`** for tile grids to collapse draw calls.
- Never `free()` a node mid-callback — always `queue_free()` (defers to end of frame).

## Data & structure

- Shared/config data as **`Resource` (`.tres`)** files, not autoload-singleton soup.
- Autoloads (singletons) are fine for true globals (audio bus, save manager) but keep them few and explicit.
- Explicit state machines (enum + `match`, or a state-node pattern) over boolean flags.

## Verify & profile

- Use the built-in **profiler and monitors** (Debugger panel) against the target device.
- Godot MCP ([Coding-Solo/godot-mcp](https://github.com/Coding-Solo/godot-mcp)) gives run + console/error capture but **no screenshots** — add an explicit screenshot step (`get_viewport().get_texture().get_image().save_png(...)` or OS capture) for the visual-evaluate stage of the frame-grounded loop.

## Review checklist (Godot)

1. `get_node()`/`$Path` called per frame? → `@onready` cache.
2. Cross-tree hard-coded paths instead of signals/`@export`? → decouple.
3. Gameplay logic in `_process` instead of `_physics_process`, or movement not `delta`-scaled? → fix.
4. Untyped GDScript in hot paths? → add static types.
5. `instantiate()`/`queue_free()` per frame for bullets/particles? → pool.
6. Many identical nodes not using `MultiMesh`/`TileMap`? → batch.
