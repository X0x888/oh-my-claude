# Unity (C#) reference

Patterns and pitfalls that survive across Unity versions. For exact API (method signatures, package versions, current best-practice APIs) verify against the installed Unity version's docs — do not rely on training memory.

## Update loop — where frame budget dies

- **Never `GetComponent`, `Find`, `GameObject.Find`, or `Camera.main` inside `Update`/`LateUpdate`.** `Camera.main` runs `FindGameObjectWithTag` every call. Cache all of these once in `Awake`/`Start`.
- **No per-frame heap allocations.** Avoid `new` in the hot loop, LINQ in `Update`, string concatenation (`"Score: " + n`), and `foreach` over types that allocate an enumerator. Reuse buffers and `StringBuilder`.
- **Cache `WaitForSeconds`/`WaitForFixedUpdate`** instead of allocating a new one each coroutine iteration.

## Physics & timing

- Physics and `Rigidbody` forces go in **`FixedUpdate`**; input sampling in `Update`. Multiply by `Time.deltaTime` (Update) / `Time.fixedDeltaTime` (FixedUpdate) so motion is frame-rate independent.
- Do not move a `Rigidbody` by setting `transform.position` — use `MovePosition`/forces, or the physics solver fights you.

## Spawning & memory

- **Pool frequently spawned objects** (bullets, VFX, enemies). Unity ships `UnityEngine.Pool.ObjectPool<T>`; reuse it rather than `Instantiate`/`Destroy` each frame (Destroy churns GC and triggers collection hitches).
- Stream large assets with **Addressables**; set memory budgets; release handles. Loading mid-gameplay causes stalls — preload at scene boundaries.

## Structure & data

- Prefer **ScriptableObjects** for shared config/data and event channels over static singletons — testable, inspector-editable, no hidden global state.
- Decouple systems with events/`UnityEvent`/ScriptableObject channels rather than direct cross-references.
- Explicit state machines for entity/animation/UI state, not boolean flags.

## Draw calls & rendering

- Cut draw calls: **SRP Batcher**, **GPU instancing**, static batching, shared materials, sprite/texture atlases. Draw-call count is the most common silent perf killer — check the **Frame Debugger**.
- Measure with the **Profiler** (CPU/GPU/memory) and **Frame Debugger** against the target device, not the editor.

## Review checklist (Unity)

1. Any `GetComponent`/`Find`/`Camera.main` in `Update`? → cache it.
2. Allocations in the hot loop (LINQ, `new`, string concat)? → remove.
3. `Instantiate`/`Destroy` per frame? → pool.
4. Physics outside `FixedUpdate` or movement not delta-scaled? → fix.
5. Draw calls batched, materials shared, atlases used?
6. Frame budget measured on the target device (16.6ms@60 / 8.3ms@120)?
