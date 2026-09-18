# vyper IDEAs

Speculative directions, parked for when a roadmap phase reaches them. Not
commitments — TODO.md is the work queue; this is the bank. When an idea here
gets picked up, move it to TODO.md with a concrete design and steps.

## Audio: plugin hosting (LV2 / VST3) + built-in DSP

**Question:** does it make sense to eventually support LV2/VST3 plugins for audio
manipulation? Gain, envelope, panning, volume, and automation are planned anyway.

**Position:** yes, eventually — but as an *adapter over an internal effect/param
layer*, never as the foundation. Built-ins come first; the plugin host maps onto
the same interface. Sizing: a plugin host is a subsystem on the order of the
proxy pipeline, not a feature.

### Staging

1. **Generic parameter + insert model (do this first, format-independent).**
   An `Audio_Effect` with a block `process(in, out, frames)` and a parameter list
   (id, name, normalized 0..1 value, default, automation target). Gain, pan,
   volume, and envelope are just the first implementations; automation lanes drive
   their parameters exactly as they would a plugin's. Nothing here references LV2
   or VST3 — that is the point: solve the DSP problem you actually have (AGENTS
   §2/§3), and let plugins be one more implementation later.
   - Serial insert chain per track (and later per clip), matching today's
     single-active-audio-clip model. Sends/buses/sidechain are a later graph step.
   - Parameter id ↔ automation curve binding is the shared piece: automation is a
     host concern, so a parameter change must be expressed the same way for a
     built-in and for a hosted plugin.
2. **LV2 host — the first plugin format.** Pure C ABI (`LV2_Descriptor`,
   `run()`, typed ports, `.ttl` metadata). Resolve with `dlopen`/`dlsym`, connect
   audio + control ports, call `run()` per block. Maps cleanly onto Odin FFI with
   no shim. Cross-platform (Linux/macOS/Windows), ISC licensed. Host a small,
   well-behaved set first (EQ, compressor).
3. **VST3 — later, and only if demand justifies it.** Steinberg's ABI is a C++
   COM-style interface, so hosting from Odin needs a small C/C++ shim and the SDK.
   Licensing is dual GPLv3 / proprietary (a proprietary product needs a Steinberg
   agreement). Same internal interface as LV2 — the format must not leak past the
   host adapter.
4. **Sandbox — before shipping plugins to users.** A misbehaving plugin in the
   audio callback glitches or stalls the real-time thread; a crash takes the app
   with it. Run plugin instances out-of-process with a shared-memory ring for
   audio/params (a bounded queue with a named overflow policy, per AGENTS §1), or
   at minimum a watchdog + auto-bypass. This is the audio-thread version of the
   "never stall on a producer" rule and is not optional once third-party code is
   in the callback.

### Constraints (mapped to this codebase)

- **RT thread stays clean:** the plugin's own `run()` may allocate — ours must
  not around it. Plugin instances live session-heap; scratch/param staging uses
  fixed buffers, never `context.temp_allocator` across a thread hop.
- **Buffer lifetime** (AGENTS §1): plugin `run()` may retain port buffers; know
  which, and give each outliving consumer its own buffer.
- **Sample rate / block size:** host owns both; negotiate or resample, and assert
  the contract. Latency reporting (`latency` port / VST3 `getLatencySamples`) must
  feed a plugin-delay-compensation path or tracks drift.
- **Parameters are a closed, named set:** normalized 0..1 with proper ranges,
  never a bare index. Automatable params are the single source of truth that both
  the UI and the automation lane read.
- **Editing model** (AGENTS §2): discrete param edits commit (bump generation,
  undo seam); automation drawing mutates + dirty flag, no commit per frame.
- **Persistence:** project stores plugin URI + path + state blob. A missing
  plugin is a recoverable error (skip + warn), never an assert — projects move
  between machines.
- **Scanning:** out-of-process scan with a blacklist; a broken plugin must not
  hang startup.

### Open questions (resolve when picked up)

- Graph routing: serial inserts only vs. sends/buses, and where the split happens.
- Sidechain inputs, and how they fit the timeline model (a bus? a clip ref?).
- Plugin GUI: embedded windows vs. a generated generic-parameter panel. Start
  generic-only.
- State/undo granularity for plugin presets vs. built-in params.
- How automation lanes are authored/drawn on the timeline (shared with the
  envelope work) — likely the prerequisite for the whole feature.

**Recommendation:** build the generic parameter + insert model with built-ins
(gain/pan/volume/envelope) and automation first; add LV2 as the first host
adapter once that interface is stable; treat VST3 and the process sandbox as
later, demand-driven steps.

## (Add new ideas below, newest first.)
