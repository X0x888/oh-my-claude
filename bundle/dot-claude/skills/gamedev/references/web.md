# Web / HTML5 games reference (Phaser, Babylon.js, PixiJS, Three.js)

Patterns and pitfalls common to browser game engines. JS GC pauses and the single main thread make allocation discipline and the fixed-timestep loop especially load-bearing. Verify engine-specific API (Phaser 3.x scenes, Babylon 7.x, etc.) against current docs (via the `librarian` agent or `context7` MCP).

## The game loop

- Drive the loop with the engine's own update (Phaser `Scene.update`, Babylon `scene.onBeforeRenderObservable`) or `requestAnimationFrame` — never `setInterval` for the render loop.
- **Fixed-timestep accumulator** for simulation determinism: accumulate real delta, step the sim in fixed increments, interpolate render. Decouple update from render.
- **Cap delta-time.** After a tab switch or stall, `dt` can be huge → "spiral of death." Clamp it (e.g., max 1/30s) before stepping.
- Multiply all movement by delta.

## Allocation & GC (the JS-specific killer)

- **No per-frame allocations**: no object literals, array literals, closures, or `vec`/`{x,y}` creation in the loop. GC pauses are directly visible as stutter. Reuse vector/temp objects; mutate in place.
- **Pool sprites/particles/projectiles** — show/hide and reset rather than create/destroy.

## Rendering & assets

- Cut draw calls with **texture atlases / sprite sheets**; minimize texture binds and shader switches.
- **Preload assets** in a boot/preload scene (Phaser `preload()`, Babylon `AssetsManager`) — never load mid-gameplay; it stalls and pops.
- **Cull offscreen** objects from update and render; don't tick what isn't visible.
- Handle **WebGL context loss** (`webglcontextlost`/`restored`) — mobile browsers drop it.
- Respect `devicePixelRatio` for crisp rendering without over-rendering on high-DPI/mobile.

## Input & audio

- Buffer pointer/keyboard events; consume them in the fixed update — don't act directly in the event handler.
- **Unlock audio on the first user gesture** (browser autoplay policy blocks audio until then) — a near-universal "no sound" bug.

## Structure & profiling

- Use the engine's scene/state manager (Phaser Scenes) instead of ad-hoc module globals.
- Profile with the browser **Performance panel**; the **Chrome DevTools MCP** ([ChromeDevTools/chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp)) can capture traces, and **Playwright MCP** can drive the canvas and read console errors for the frame-grounded loop.

## Review checklist (web)

1. Render loop on `requestAnimationFrame`/engine update, not `setInterval`?
2. Delta clamped and applied to all movement; fixed-timestep where determinism matters?
3. Per-frame allocations/closures in the loop? → reuse objects, pool sprites.
4. Assets preloaded, atlased, offscreen culled?
5. Audio unlocked on first gesture; WebGL context-loss handled?
6. `devicePixelRatio` and touch targets handled for mobile web?
