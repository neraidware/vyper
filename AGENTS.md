# AGENTS.md

Engineering philosophy for this codebase. Every change should satisfy these, in
order, or consciously deviate with a comment saying why.

## 1. Follow the Odin compiler / language, and its style

- Write code the Odin compiler is happy with first and always: no hacks to
  satisfy another toolchain, no patterns the language itself rejects. The
  compiler's warnings, `-vet`, and the core idiom are the style guide.
- Use the latest language features where they make code simpler, but never
  where they complicate a thing that works. New feature off the shelf — if the
  old, plain line was clearer, keep the plain line.
- Declare types and procedures before use; no forward-declaration gymnastics.
- Prefer data-oriented layout: `#packed` structs for on-disk/wire formats,
  `#soa` where iteration skips, flat arrays over linked/pointer-chasing
  structures.
- Favor tagged unions over `rawptr` + casts. If a union won't work, contain the
  cast behind one well-named accessor, not inline at every caller.
- Use `switch` / `switch #partial` and `#'with` to destructure; default-case
  nothing that can be enumerated exhaustively.
- Iterate by index over slices; never hand-roll containers that `core` already
  provides well.
- Reuse hot buffers; don't rebuild the same scratch inside a loop.
- Hand-rolled solutions (own containers, mini frame formats, custom fiddly
  loops) are fine when nothing existing solves the problem well — but avoid
  them otherwise: every hand-rolled widget is an implementation we maintain,
  not a dependency. Favor `core`/vendored libs unless they provably don't fit.
- "Clean" here means code that does exactly what it needs to and no more —
  not idiomatic ceremony a Java reviewer would applaud. Fast, understandable,
  simple at its core. If you must pick, pick simple and fast over "sound".

## 2. Memory model: arenas, generational handles, single-writer ownership

The memory model is the architecture. It decides how every subsystem addresses,
lifetimes, and shares its data, so the ground rules come first.

- Allocate big backing blocks up front per thread / per subsystem; carve from
  them instead of touching the general allocator.
- Hot paths (per frame, per decode, per proxy segment) must not allocate from
  `context.allocator`. Use `context.temp_allocator` for frame-scoped scratch
  and an arena or fixed buffer for anything reuse-shaped.
- A surprise heap allocation in a hot loop is a bug, not an optimization
  opportunity.
- Static nothing; pre-sized everything. Explicit ownership: caller passes the
  buffer, callee fills it.
- **Avoid individual allocations.** A one-off `make([]T, 1)`, per-item `new`,
  per-call pair of `make`+`delete` is expensive and breeds bookkeeping bugs
  (leaks, stale-length reuse after `delete`, µff-by-one lifetimes). Allocate in
  bulk or from the pool/model that owns the shape: fixed slot arrays with an
  `in_use` flag (preview_slots), grow-only append buffers (srt_cache), arena
  scratches. `new`/`delete` on single objects happen rarely, deliberately, at a
  teardown/ownership boundary — not inline in a routine that runs per frame or
  per cue.

### Address by handle, never by a pointer you keep

- Refer to movable/recyclable things by a stable handle — `(id, generation)` —
  never a stored `^T`. A pointer lives one frame: resolve at the use site, drop
  it after. This is already the house pattern: `Clip.clip_id` (assigned once,
  never mutated by drags), the append-only `srt_cache` (its indexes stay valid
  because nothing there is freed), the fixed `preview_slots[]` pool with its
  `in_use` flag.
- Recycling a slot bumps its generation; a stale handle resolves to "gone",
  loudly. Never let an old handle alias a reused slot.

### Single writer per structure; hand off, don't lock

- Each buffer/queue has exactly one writer at any time. Cross-thread reads ride
  an atomic index/generation handoff; never a mutex guarding a hot buffer.
  Arena + ownership means no GC, no refcounts, no lock contention.
- Cross-thread queues are bounded with a named overflow policy: decode behind →
  drop the oldest preview frame; audio behind → catch-up burst. Never stall the
  render thread on a producer.
- Mutable hot state that several threads poke per frame lives on its own cache
  line; keep unrelated hot counters off shared lines.

### Commit or mutate, by edit kind

- Discrete edits (import, split, delete, parameter change) build a candidate and
  commit it: the commit bumps a generation, and any cache keyed on that
  generation drops stale entries for free. This is also the future undo model's
  seam — an undo log is a cursor over commits.
- Continuous interactions (dragging a clip, scrubbing) mutate in place and set
  a dirty flag; no commit per frame.

### Ownership matrix (audited)

Every allocation falls into exactly one bucket; name the bucket when you
allocate. `delete` must pair with each heap `make`/`new` at that bucket's
teardown; `free_all(context.temp_allocator)` (main.odin frame loop, once per
frame) is the ONLY thing that frees frame-scoped memory.

- **Session heap** — owner is the owning struct; freed at teardown, never
  before. Track/clip `name` + `metadata`, clip `markers`, decoder caches
  (decode buf, `dec.s16`), `ui_notice_text`, `srt_cache` (append-only, never
  freed mid-session), clay's memory block. Nothing per-frame may grow here.
- **Caller heap** — a proc returns a buffer the caller must `delete` (or
  `defer delete`). Examples: subprocess result strings, textinput paste cstr,
  decode `markers` return, media dynamic `out` (deleted + cloned into a
  persistent string). If a proc allocates and hands back a string, the callee
  never frees.
- **Frame temp** — `context.temp_allocator`, dead at the next frame start
  (free_all at main.odin:975 and only there). Timeline edit temporaries, the
  per-line raster buffers in `rasterize_lines_into_buffer`, decode thumbnail
  scratch, `ff_err_str`, probe env strings. A frame-scoped pointer/string must
  never be stored on a struct or ride a thread hop across a frame boundary.
- **Worker job arena** — the render job's own arena, destroyed with the job
  (render.odin worker teardown). Canvas, text/subtitle jobs, one-slot caches
  ride it; nothing survives job teardown, which is why the worker's font/
  scratch lives outside the arena.
- **Probe rule** — a headless probe that simulates the frame loop free-alls
  the temp arena itself, so any string it must keep (paths built from
  `lookup_env_alloc`) must be cloned to heap first. Temp-backing a value a
  probe reads after a simulated frame is a dangling buffer (subtitle probe
  hit this: env path read after the first free_all).

Two violations this model has already caught (both were real segfaults):

- textclip.odin:282 — the rasterizer's ink rect can overshoot its galley
  (negative `lox`/`loy`), so both the per-glyph writes and the composite reads
  must clamp to the line buffer on BOTH axes. The write side always clamped;
  the read side didn't, and `-no-bounds-check` turned the OOB read into a SEGV
  only after line buffers moved from a reused 4 MB blob to fresh temp slices.
- Probe env strings were temp-backed and read after a simulated-frame
  `free_all` (see above).

## 3. Low level is home turf: raw data, memory, and the unknown

- Raw bytes, pointer math, bit twiddling, `transmute`, `offset_of`, packing —
  none of that is scary. The GPU and the file formats we decode are low-level;
  so is the code that talks to them. Write the low-level thing directly when it
  is simpler or faster than the abstraction over it.
- "Messing with the unknown" (an unfamiliar format, an undocumented structure,
  a weird alignment) is how this project learns. Probe it, instrument it, dump
  bytes until it makes sense — then contain what you learned behind a clean
  accessor.
- Low-level does not mean sloppy: any place raw data flows in, name the layout
  (`#packed` struct, explicit size constants), assert invariants, and own the
  memory. Fearless is compatible with careful.
- Prefer a `[]u8`/`rawptr` + one named accessor over a chain of speculative
  indirection. When the data model is bytes, model bytes.

## 4. Solve the simple problem simply

- If a plain loop or a one-line condition fixes it, that is the fix. Introduce
  a new subsystem only when the old one provably cannot express the problem.
- Avoid cleverness: no indirection for its own sake, no machinery sized for a
  problem we do not yet have.
- When a design starts to need escape-hatches and special cases, that is a
  signal the abstraction is wrong, not that it needs more flags.
- Similarly, when a system is complicated enough that even the simplest thing
  has become unscalable to do, stop patching it — consider a more complete
  system that simplifies the overall architecture. Sometimes the "bigger"
  design is the simpler one.

## 5. Asserts are your friend — use them wherever an invariant can be stated

- Any condition the later code depends on: assert it (bounds, non-nil, enum
  validity, cache-key match, decoded state).
- Assert loudly at the cause, never swallow-and-continue to the symptom.
- When a bug is unclear, write an assert or a probe to characterize the
  violation first; then decide whether the guard should stay an assert or
  become a handled case. A silent `return` where an invariant was violated is
  how desync bugs survive.
- Asserts live in all builds; they are the documentation of what must never
  happen.

## 6. Logging is useful, not automatic

- Log user-facing errors and state transitions. Do not log per-frame or
  per-iteration noise — that is what counters and the profiler are for.
- When something must be observable at runtime, prefer a structured line over a
  scattering of debug prints.
- Probes (cache/frame/boundary) are the reproducibility tool, not logging.

## 7. Be explicit and readable. No magic numbers; comments where useful.

- Every bare number is a named constant (proxy segment size, preview dims,
  thread counts, timeouts). If you must inline a number, the page must already
  name it.
- Prefer code that states intent; comment where code alone cannot explain
  itself: the why, cross-file invariants, coupling to a probe or a cached
  value, a non-obvious decision. Never restate what the code already says —
  if a comment would only repeat the line, the line wins.
- Short identifiers only when the scope is tiny; err on the side of naming.

## 8. Spall is the profiler; use it wherever performance matters

- Any hot path worth touching is worth measuring first with
  `spall_scope(#procedure)` and `NERED_SPALL=/tmp/x.spall`; full call-tree
  captures with `-define:NERED_INSTRUMENT=true`.
- Perf claims ship with a Spall trace or a probe measurement, not vibes.
- Check the capture size — a 35 s full-tree trace is ~20 MB/s; trim with
  `NERED_SPALL_MS` and manual markers for steady-state work.