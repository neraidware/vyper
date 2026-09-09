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
- "Clean" here means code that does exactly what it needs to and no more —
  not idiomatic ceremony a Java reviewer would applaud. Fast, understandable,
  simple at its core. If you must pick, pick simple and fast over "sound".

## 2. Memory: arenas (large pre-allocated chunks) are the default approach

- Allocate big backing blocks up front per thread / per subsystem; carve from
  them instead of touching the general allocator.
- Hot paths (per frame, per decode, per proxy segment) must not allocate from
  `context.allocator`. Use `context.temp_allocator` for frame-scoped scratch
  and an arena or fixed buffer for anything reuse-shaped.
- A surprise heap allocation in a hot loop is a bug, not an optimization
  opportunity.
- Explicit ownership: caller passes the buffer, callee fills it. Static
  nothing; pre-sized everything.

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