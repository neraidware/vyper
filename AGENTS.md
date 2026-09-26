# AGENTS.md

Engineering philosophy for this codebase. Every change should satisfy these,
in order, or deviate with a comment saying why.

## 0. TODO.md is the project state tracker

- Record in TODO.md **any and every change that affects the final result of
  the project** — a new feature, a behavioral change, a fix that changes
  output. Keep one Active section per work-stream, with the same
  steps-probe-accept structure the rest of the file uses. Update it in the
  same commit as the code it describes (or right before, when the steps are
  being checked off mid-work).
- Not tracked: scratch, probe-only churn that changes nothing shipped, and
  experiments that were reverted before landing. If it touched the shipped
  behavior of the app, even temporarily, it goes in the file.

## 1. Memory model: arenas, generational handles, single-writer ownership

The memory model is the architecture — it decides how every subsystem
addresses, lifetimes, and shares data. Everything else follows from it.

- Ownership (who frees it) and lifetime (how long it stays valid) are
  different questions. A caller-heap buffer is owned by whoever allocated
  it, but its lifetime is decided by the caller that received it. Don't
  conflate the two when debugging.
- Most allocations here are size-known + lifetime-known — the easy case the
  ownership matrix below is built for. When one isn't, name which dimension
  is unknown before reaching for a general-purpose container. Group storage
  by shared lifetime rather than by object; if several things die together,
  they should usually live in the same arena or teardown boundary.
- Allocate big backing blocks up front, per thread or subsystem, and carve
  from them. Don't touch the general allocator on a hot path — use
  `context.temp_allocator` for scratch, an arena or fixed buffer for
  anything reuse-shaped. A surprise heap allocation in a hot loop is a bug.
- Pre-size everything with a real bound from the problem. Caller passes the
  buffer, callee fills it.
- Avoid individual allocations — a one-off `make([]T, 1)`, a per-item `new`,
  a `make`+`delete` pair per call breeds leaks and stale-length bugs. Prefer
  fixed slot arrays with an `in_use` flag, grow-only append buffers, or
  arena scratch. `new`/`delete` should happen rarely, at a real teardown
  boundary — never inline in a routine that runs per frame or per cue.
- Per-frame text/ids format into fixed buffers, never allocate:
  `fmt.bprintf` into a `[64]u8`/`[512]u8`, not `fmt.aprintf`/`tprintf`/
  `strings.concatenate`. A few KB fixed costs nothing; allocating the same
  string every frame is real work, and a leak if it's heap.
- **Buffer lifetime must cover every reader, not just the writer's stack
  frame.** Some APIs copy what you hand them; some retain the pointer and
  read it later. Know which. If it retains, one buffer feeding several
  outliving calls means each reads whatever the buffer holds *last* — use
  one buffer per thing that outlives the call unless you've confirmed the
  callee copies. Never read a temp pointer after `free_all` of its arena.
  When two similar-looking values crossing the same boundary get different
  treatment — one copied defensively, one stored raw — say why in one
  line. An undocumented asymmetry reads as a bug to the next person, even
  when it's a deliberate call (e.g. one is a stable session-heap string,
  the other isn't).

### Handles, not pointers

- **Handle-indexed flat arrays are the default container shape.** A `[]T`
  indexed by handle beats a linked list or `^Node` tree for almost
  everything here: cache-friendly, trivially iterable, no per-node alloc,
  `#soa`-able later. Reach for pointer-based structures only when the
  shape genuinely isn't array-like — unbounded branching, a graph with no
  natural bound — not because it's the familiar way to model a collection.
- Movable/recyclable things get a handle, `(id, generation)` — never a
  stored `^T`. Resolve a pointer at the use site, drop it right after.
  Sketch: `Handle :: struct { id: u32, gen: u32 }`; lookups must assert
  the generation matches (`slots[h.id].gen == h.gen`) before use.
- Reserve index 0 as "nothing" for handle arrays. A zero-valued handle should
  never alias a real object.
- Recycling a slot bumps its generation. A stale handle resolves to "gone,"
  loudly — never let an old handle alias a reused slot.
- A resolved pointer is only valid until the backing array can move. Do not
  hold pointers across growth or compaction; use a handle, fixed capacity, or
  a staging list committed after the pointer is no longer in flight.

### Single writer per structure; hand off, don't lock

- One writer at a time, always. Cross-thread reads ride an atomic index/
  generation handoff (`intrinsics.atomic_store_rel` to publish, swap to
  consume — never a mutex on a hot buffer) — this is what lets arena +
  ownership skip GC, refcounts, and lock contention.
- `core:sync` atomics for hot handoffs; `sync.Mutex` only for cold paths
  (config reload, init). A mutex on anything touched per-frame means the
  design is wrong, not that you need a lock.
- Bound cross-thread queues with a named overflow policy — decode behind
  drops the oldest preview frame, audio behind catch-up-bursts. Never stall
  the render thread on a producer.
- Hot state touched by multiple threads gets its own cache line. Pad
  explicitly with `#align 64` or a named `_pad: [64]u8` — don't rely on
  incidental layout.

### Commit or mutate, by edit kind

- Discrete edits (import, split, delete, parameter change) build a
  candidate and commit: the commit bumps a generation, and caches keyed on
  it drop stale entries free. Also the seam for the future undo model.
- Continuous interactions (dragging, scrubbing) mutate in place, set a
  dirty flag. No commit per frame.

### Ownership matrix — name the bucket when you allocate

- **Session heap** — owned by the struct, freed at teardown only. Track/
  clip name and metadata, markers, decoder caches, the append-only
  `srt_cache`. Nothing per-frame grows here.
- **Caller heap** — proc returns a buffer the caller must `delete`/`defer
  delete`: subprocess strings, textinput paste, decode `markers`, a media
  `out` string cloned into something persistent. Callee never frees.
- **Frame temp** — `context.temp_allocator`, dead next frame (`free_all` in
  the main frame loop, and only there). Edit temporaries, raster scratch,
  transient error strings, probe env strings. Never store on a struct or
  carry across a thread hop.
- **Worker job arena** — dies with the render job. Canvas, text/subtitle
  jobs, one-slot caches ride it; anything that must outlive the job (font,
  persistent scratch) lives outside the arena.
- **Probe rule** — a headless probe simulating the frame loop does its own
  `free_all`. Anything it needs past that point must be cloned to heap
  first, or it's a dangling read.
- **A setup proc that acquires several resources must unwind on partial
  failure.** If step 3 of 5 fails, steps 1 and 2 already succeeded and own
  live resources — release them before returning, the same way `delete`
  pairs with `make`. Applies to driver-owned handles (GPU textures,
  pipelines, samplers) as much as heap memory — nothing else in the
  ownership model catches a leaked GPU resource on an error path. Prefer
  `defer` per acquisition so cleanup is automatic, rather than hand-writing
  the unwind at each early return.

### Hot-path data structures: the shape must fit the access pattern, the score must implement the policy

- **A FIFO on a real-time thread is a ring buffer, not a shifting slice.**
  Fixed capacity, head/tail indices, wrap — never `mem.copy` the tail down
  and `resize` per pushed element. An O(n) move per element is O(n²) per
  second, and each `resize` is exactly the per-frame allocation the ownership
  rules above forbid, on the one thread that must never stall. The per-source
  audio fifo is the reference: a shifting array there re-copied the whole
  queue every mixed frame per source.
- **A cache's eviction score must compute the policy its name and comment
  claim.** A monotonic `uses` counter is "most-frequently-ever", not LRU;
  recency needs a stamp that advances (a `last_touch` from a clock), not a
  counter that only ever increases. The decode cache called its counter LRU
  while it never decayed. When the comment and the score disagree, the
  comment is a lie the compiler cannot catch — fix the score, not the
  comment.
- **The tell for both is structural, not behavioral:** an allocation or an
  O(n) move inside a per-frame or per-sample loop, or a metric that only ever
  increases. Neither shows up in review because both read plausibly — the
  container "works", the eviction "picks something". Name the access pattern
  (push/pop at one end, recency) and pick the structure from that, not from
  the shape that was easiest to write.

## 2. Write Odin, not generic code translated to Odin

- Compiler happy first: `-vet` clean, no hacks aimed at another toolchain's
  habits. Compiler warnings and core idiom are the style guide.
- Think in data transformations, not type hierarchies: model the data and
  write the direct algorithm that transforms it. This is Odin's design
  principle, and it is the common thread behind enums, switches, flat arrays,
  and explicit ownership.
- New language features earn their place only if they simplify a line. Old
  plain line beats new fancy one.
- Declare in reading order — Odin doesn't need forward declarations, don't
  restructure a file pretending it does.
- Data-oriented layout: `#packed` for wire formats, `#soa` where iteration
  skips fields, flat arrays over pointer-chasing.
- Tagged unions over `rawptr` + casts. If a union won't work, contain the
  cast behind one named accessor, not inline at every caller.
- Reuse logic through composition — a shared proc, an embedded struct
  where behavior is genuinely shared, a table when "differences" are just
  constants — not copy-paste-and-tweak, which means every future fix has
  to land in both places and eventually only lands in one.
- `switch`/`switch #partial`/`#with` to destructure; no default-case on an
  exhaustible enum. Prefer a long switch over any hand-built dispatch
  simulation — vtable-style function-pointer structs, `map[Type_Tag]proc`
  registries, `any`/`reflect` type erasure, embedding-as-inheritance,
  visitor patterns. These buy adding a case without touching the switch,
  which only pays off if new cases come from outside your control. If you
  own the whole closed set, the switch is honest, every case is visible,
  and a direct call beats an indirect one.
- **A closed set of cases is a named type, never a bare int.** If a value
  picks between a fixed, enumerable set of states, give it an `enum`, not
  `0`/`1`/`2` with a comment saying what each number means. A comment is
  easy to let drift from the actual cases; the compiler checking a
  `switch` against real enum members isn't. This has shown up multiple
  times as int-coded state where an enum would have caught a typo'd case
  number at compile time instead of silently doing nothing at runtime.
- When a mapping must stay in lockstep with an enum or other single source
  of truth, derive the table from that source instead of maintaining parallel
  hand-written cases. Generate it once the duplication is large enough to
  justify the machinery.
- Index over slices; don't hand-roll a container `core` already has. Reuse
  hot buffers instead of rebuilding scratch inside a loop.
- **Abstraction must pay rent** — in speed or invariant-safety, not
  vibes. A bounds clamp, a generation tag, a named `#packed` layout pay
  rent. A generic `Container(T)` nobody will swap, a cast hidden behind an
  unneeded accessor, don't. Reach for `core`/vendor before inventing;
  invent only when nothing fits, and keep it small.
- Clean = does exactly what's needed, no more. Simple and fast beats
  "sound" when forced to choose.
- **Make the zero value useful.** `Foo{}` shouldn't need an `init()` before
  it's safe to touch — a valid generation of 0, an empty-but-iterable
  slice, a harmless zero-state enum. Hold every new struct to this bar.
- Solve the specific problem you have. Going generic loses the shape,
  access pattern, and size bound that would've made it simpler *and*
  faster. Different data shapes are different problems — apparent conceptual
  similarity is not enough reason to share a path.

## 3. Solve the simple problem simply

- Plain loop or one-line condition fixes it? That's the fix. New subsystem
  only when the old one provably can't express the problem.
- Write it inline at the call site first. Extract a shared proc only when
  identical patterns already exist in 3+ distinct locations — extracting
  for reuse you don't have yet is speculative.
- No indirection for its own sake, no machinery for a problem you don't
  have yet.
- Needing escape hatches and special cases signals the abstraction is
  wrong — fix the shape, don't add flags around it.
- If even the simplest change is unscalable in the current system, stop
  patching and redesign. Sometimes bigger is simpler overall.
- Start specific and let working code reveal the abstraction. The right time
  to generalize is when repeated structure is visible, not when it is merely
  predicted.

## 3b. No workarounds

- A workaround targets the symptom, not the defect. Not "avoid when
  possible" — not allowed.
- Buggy, confusing, or wrong code: fix it, refactor it, clean it up. No
  special case, guard clause, retry, or reordering that hides the symptom
  while the cause stays live for the next person or code path to hit blind.
- Worse than doing nothing — the symptom stopping removes the pressure to
  fix the real thing.
- Signs you're about to write one: you don't fully understand why the bug
  happens but found an input that avoids it; the change lives far from the
  actual defect; you're about to write a comment explaining why this weird
  thing is here instead of fixing what made it necessary.
- Genuinely can't fix it now? Say so at the actual defect site, not just
  the call site papering over it — so the next person finds the real
  problem, not another layer on top.

## 3c. Boundaries should stay cheap to change

- A module is a black box: keep its interface narrow enough that the
  implementation can change without forcing callers to change.
- Do not leak internal assumptions through an interface unless the caller
  actually needs them. An interface should not dictate another subsystem's
  allocator, data layout, or internal representation.
- Treat persisted formats and other cross-subsystem contracts as APIs. Change
  them deliberately because every dependent caller pays the migration cost.

## 4. Low level is home turf

- Raw bytes, pointer math, bit twiddling, `transmute`, `offset_of`,
  packing — not scary, just the job. Write it direct when direct is
  simpler or faster than the abstraction.
- Unfamiliar format or structure: probe it, dump bytes until it makes
  sense, then contain what you learned behind one clean accessor.
- Low-level ≠ sloppy: name the layout (`#packed`, explicit size constants),
  assert invariants, own the memory.
- `[]u8`/`rawptr` + one named accessor beats a chain of speculative
  indirection. Bytes are bytes — model them as bytes.

## 5. Errors: values for recoverable, asserts for invariants — never mixed

- **Recoverable** (bad file, dropped frame, non-critical OOM, bad input) is
  data, not a bug. Return `(T, ok)`/`(T, err)`. `or_return` to thread up a
  chain, `or_else` for a real fallback. Never `panic` on user-triggerable
  input.
- **Invariant violation** (cache mismatch, wrong-handle resolve, unhandled
  enum case) is a bug — assert it (§6) where it's caught, don't launder it
  into a normal error return.
- **Handle it where it happens; don't reflex-bubble it.** `or_return` is
  for legit propagation, not the default. Ask if this proc can actually act
  on the failure — if so, handle it here instead of passing it up for
  "someone else." An `or_return` chain that terminates several callers away
  with nobody able to act is the "pass it up" problem exceptions have, just
  type-checked instead of silent — the type system makes it visible in
  review, it doesn't prevent it.
- Test: caller can meaningfully continue → error value. Only a code fix
  helps → assert. Unsure → assert first; loud-wrong beats silent-wrong
  three subsystems later.
- Invariant asserts run in all builds, no `when ODIN_DEBUG` gate. Debug-
  only guards only for checks proven too expensive for release.

## 6. Assert everything you can state

- Any condition later code depends on: assert it — bounds, non-nil, enum
  validity, cache-key match, decoded state.
- Assert loud, at the cause. Never swallow-and-continue to the symptom.
- Bug unclear? Write an assert/probe to characterize it first, then decide
  if it stays an assert or becomes a handled case (§5). A silent `return`
  on a violated invariant is how desync bugs survive.
- **Truncating or clamping data into a fixed buffer is silent data loss
  if nothing signals it happened.** Copying a too-long string into a
  `[N]u8` and just continuing is the same failure mode as swallowing an
  invariant — the operation "succeeded" but on the wrong data, and
  nothing downstream can tell. If truncation should never happen, assert
  the length first. If it can legitimately happen, log it — silence is
  what turns a clipped path or a cut-off label into a mystery three bug
  reports later.
- Asserts run in every build — they're the doc of what must never happen.
- **Crashing is good, not a failure.** An assert failure downgrades a
  catastrophic bug into a liveness bug: work stops, but the trace points at
  the cause, and no corrupt state gets written where other systems will
  later trust it. Swallowing the violation doesn't fix it — it defers
  discovery downstream, buried under everything that ran after. Crash-at-
  assert beats wrong-answer-five-frames-later.
- **Pair assertions across the boundary that matters.** Invariant set in
  one place, relied on far away — decode thread writes it, render thread
  reads it; commit bumps a generation, cache checks it — assert both ends.
  A single assert catches "wrong right now"; the pair catches "silently
  drifted apart since." Can only think to assert once? Find who else
  depends on it, assert there too.

## 7. Logging is useful, not automatic

- Log user-facing errors and state transitions — a failed export, a
  dropped connection, a mode switch. Not per-frame noise; that's what
  counters and the profiler are for.
- Runtime observability = one structured line, not scattered debug prints.
- Probes are the reproducibility tool for a specific bug — don't reach for
  logging when you need a rerunnable probe instead.

## 8. No magic numbers. Name things. Comment the why.

- Every bare number is a named constant. Inline only if the page already
  names it.
- Comment what code can't say: the why, cross-file invariants, a coupling
  to a probe or cached value. Never restate the line — if a comment would
  just repeat it, the line wins.
- Short identifiers only in tiny scopes. Default to naming clearly.

## 9. Spall is the profiler; use it wherever performance matters

- Measure first with `spall_scope(#procedure)` before touching a hot path.
  If you cannot explain the cost of a proposed optimization, you do not yet
  understand the performance problem (Acton/Blow).
- Perf claims ship with a trace or probe measurement, not vibes. Trim
  capture size with manual markers rather than full-tree capturing a
  whole session; the env vars that control this live in the build
  script, not memorized.

## 10. Build flags live in scripts, not your head

- Typing any build/profiling flag by hand instead of running a named
  script target means the script is missing that target — fix the
  script, don't memorize the invocation.
- `-vet` clean and warning-free is the baseline for every change, not a
  pre-release chore.

## 11. Source code is the source of truth

- Unsure how a `core:`/`vendor:` proc behaves? Read it. Odin root and
  vendored libs are on disk — check before guessing, before trusting
  memory or docs. Docs drift; source doesn't.
- Same for third-party C libs we bind against (ffmpeg, etc.) — header/
  source is the spec, not a remembered signature or blog post.
- Recalled API knowledge is a hypothesis, not a fact — verify against the
  version actually vendored here.
- Surprising behavior? Read the implementation before writing a
  workaround. The workaround is often wrong; the implementation tells you
  what's actually happening.
