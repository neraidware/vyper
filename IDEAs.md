# vyper IDEAs

Speculative directions, parked for when a roadmap phase reaches them. Not
commitments — TODO.md is the work queue; this is the bank. When an idea here
gets picked up, move it to TODO.md with a concrete design and steps.

## Working assumption: no backward compatibility

vyper is a single-user editor. There is no stable-format promise: project files,
session state, proxy layouts, undo histories can be reshaped freely. Persistence
decisions (AGENTS §3c) are cheap. This holds until a second person is affected.

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

## 1.0 milestone: undo/redo tree with branching

**Why:** the editing model already has the undo seam — AGENTS §1's discrete edits
build a candidate and commit, and the commit bumps a generation (caches keyed on
it drop stale entries for free). That is exactly the "future undo model" hook.

**The constraint that kills a stack:** editing after an undo must not destroy the
undone work. History is a tree, not a stack.

- Undo/redo walk a branch; every new edit forks a child of the current node
  (Godot-style). Moving a clip while one step under forks a branch instead of
  throwing the discarded tail away.
- Redo is enabled only down the current branch; a non-leaf edit forks, so the
  work you stepped back from survives and stays reachable.
- Commit nodes wrap the existing per-edit commit; session-side only to start —
  persisting history across sessions is a later call (and cheap, given the no
  back-compat assumption above).

**Rework-later note:** the current commit seam is one-edit-per-commit. A real
undo tree wants compound grouping (ripple delete, group move, paste = one node)
and a cheap session-heap delta capture per node so jump-to-ancestor restores
exactly. Don't build that up front — start the branch model over today's commits.

## 1.0 milestone: project manager (Godot-style)

**Position:** a launcher / session window, NOT an import or asset manager.

- Two project sources: **self-managed** (a folder the user picks, holding the
  `.vyproj` + its proxy cache) and **vyper-managed** (a directory inside vyper's
  own data folder — e.g. `~/.local/share/vyper/bank/<slug>/` — for fast throwaway
  sessions). Session-open lists both; creating a project chooses managed or not.
- Asset links resolve by absolute path (today's model) with a relative-path
  fallback so a self-managed folder can be moved. Proxies are per-project and
  regenerable, so a missing proxy is a recoverable error, never a blocker.
- The vyper bank directory is the only place the app writes outside the user's
  project; keep it behind one accessor (AGENTS §3c).

**Rework-later note:** do not build a file-metadata/asset database now. A manager
that lists folders covers 1.0; the metadata layer the NLE compositor will want
can replace the folder listing later.

## 1.0 milestone: audio clip properties (pan, volume)

**Position:** per-clip pan + volume now, kept automation-ready from the start.

- Values are normalized 0..1 parameters (volume as linear amplitude with a dB
  readout; pan as L/R balance), named — the same parameter representation the
  plugin section below routes through. This is deliberately the first slice of
  that parameter model: gain/pan/volume are built-ins there.
- Held on the Clip, applied in the audio path under the current
  single-active-audio-clip model. Editing a property = a discrete commit, so it
  rides the undo seam.
- UI: Inspector fields first; an on-clip envelope overlay can come with keyframes
  below.

**Rework-later note:** per-clip properties will have to reconcile with a
per-track/per-clip effect insert chain when that lands; pick the same data shape
up front so the migration is renaming, not reshaping.

## 1.0 milestone: keyframes for common settings

**Why:** animate/automate the properties that already exist — clip position,
scale, opacity, volume, pan — with on-clip keyframes. Later this is the
automation lane system; 1.0 keeps the minimal shape that can grow into it.

- A keyframeable property is a named parameter from the closure above; keyframes
  are `(frame, value)` pairs stored on the clip, linearly interpolated for 1.0
  (no easing/bezier yet).
- Editing = one discrete commit per keyframe change (undo seam). Playback
  evaluates against the running frame and rides the same fixed per-frame buffers
  as the transform path — no allocation on the hot path.
- Evaluation slots into clip evaluation: the preview/render pipeline already
  re-derives per frame, so a keyframe-aware parameter just supplies the value.

**Rework-later note:** the frame→value store is the germ of the automation curve
store. Keep it property-id-addressed (never a bare index) so automation lanes can
adopt it wholesale later.

## 1.0 milestone: voiceover recording

**Desire:** record a mic voiceover against the timeline from the track itself.

- Entry point: a **voiceover** item on the track's right-click context menu.
- Behavior: picking it **starts mic capture AND starts playback together**, so the
  recording lands in time against what the editor is playing.
- **No clip while recording — a ghost.** Recording shows only a ghost tile (like
  the drag ghost) of the soon-to-be clip, growing in the track under the playhead;
  nothing is committed until recording stops.
- **Collision policy (the key rule):** if the recording can't fit in that track
  — it collides with existing clips while playing — keep recording in the same
  track anyway; the collision is resolved **after** playback/recording stops, when
  the ghost materializes — spilled onto a **newly created track** so nothing is
  lost. The user then arranges or trims the result.
- Mic/input configuration (device, levels) comes later; 1.0 uses the default
  capture device.

### Staging sketches (order up when picked up)

- **Capture:** SDL audio capture device (or pipewire) → session-heap PCM buffer,
  written to a media file on stop (backed by the normal media/watch path so it
  shows up in the bin like any other clip).
- **Sync:** the recording's timeline start = playback start under the running
  clock; sample-accurate placement rides the same clock the audio render thread
  follows.
- **Ghost during record:** a semi-transparent tile (same visuals as the drag
  ghost — see `gpu_draw.odin`) grows from the playhead as the take advances,
  staying inside the lane even mid-collision; it is layout/draw-only and never
  a real clip, so nothing is committed or collided until stop.
- **Placement (on stop):** the ghost materializes via the existing
  `clip_place_in_track` at the playhead; the "overflow" pass runs once: if the
  recorded range overlaps an existing clip even after seeking to the first
  non-colliding slot in that track, create a new track and drop the clip there.
  No partial trimming, no prompts — record always, place generously.

### Open questions

- Pause/resume during record, and pre-roll countdown before playback starts.
- Where the file is written before the user commits to it (project-local scratch,
  deleted if the recording is discarded).
- Length cap / disk guard for a long take left on record.

## Later: NLE compositor (the end goal)

The whole goal of vyper is a simple-but-powerful **NLE-DAW hybrid**. The
compositor is the visual half of that: nested scenes, blend modes, transforms,
and split CANVAS vs. full-project rendering. Not for 1.0 — the four milestones
above are the 1.0 bar — but this is the direction, not a parked possibility.

## Later: automation, LV2 / VST3 plugins

Already scoped in the plugin section above. Sequence when picked up: audio
parameter + insert model with built-ins and automation lanes first; the 1.0
per-clip pan/volume/keyframe work is the first built-in implementation; LV2
adapter next, then VST3 + the process sandbox. Automation lanes and the keyframe
store share the property-id-addressed curve shape.

## Later: skew, rotation, warp (transform extrapolation)

Today's clip transform is axis-aligned (scale + position + crop, corner/edge
handles, aspect lock). Skew/rotation/warp are the step up: the axis-aligned box
becomes a four-corner (homography) model, with rotation as the first cheap case
(a rigid corner move). Non-axis-aligned geometry reaches rendering, the drag
math, snapping, and the corner-snap family; keep `transform_probe.odin` as the
parity harness so the new model must reproduce current behavior exactly before
extending it.

## Later: multi-editor-window UI, UI/render thread split

Today's model is one main loop: clay layout pass → GPU render → one surface.
Split the question in two:

- **UI vs. rendering threads:** layout and draw already ride per-frame state;
  the render worker already parallelizes export. The open part is separating the
  presentation/main-loop thread from layout + any blocking work.
- **Multiple editor windows:** e.g. keep the NLE compositor on a second monitor.
  Clay is a single-layout engine, so this is one layout pass per top-level
  surface, same renderer, per-surface input routing. The main loop fans out per
  surface; per-frame buffer and probe structure largely survive.

## Idea: keyboard-first quick editing

**Desire:** make vyper mostly keyboard-drivable for quick edits — split, trim,
nudge, ripple-delete, playhead jumping — without leaving the keys.

**Position:** worth doing, but the shape is unresolved — how to fit a keyboard
workflow onto a timeline UI (mark-in/out? playlist-style QWL? modal keys vs.
always-on shortcuts?) needs thought before committing. Parked until the mapping
is sketched.

- Grounding: shortcuts today live in one always-available switch in
  `event.odin` (F1 reference, space play/pause, H/L jog, ctrl+space project-area
  play) plus per-field edits. A keyboard-first mode extends this block with the
  timeline edit verbs, each a discrete commit so it rides the undo seam.
- The shortcut reference (F1) is the natural home for the bindings list; a
  reachable, discoverable layout is the point — hidden/undocumented keys defeat
  the goal.

### Open questions (resolve before picking up)

- Which verbs, and do any need tool-state changes (e.g. a mode) rather than a
  plain key?
- Modal (vi-style) vs. ambient: does the editor switch "modes", or is it keys
  all the time with text fields intercepting first (as they do today)?
- Structure: keep the single switch and grow it, or table-driven bindings
  (rebindable) once the set is large enough to justify the machinery (AGENTS §2)
  — the map comes after the closed set is known, not before.

## (Add new ideas below, newest first.)

## Idea: symmetrical (ghost) keyframes

**Desire:** drop a key anywhere in a clip and have an opposite ghost key
auto-mirrored to the other side of the clip. Real use case: a soft overlay —
image fades smoothly in and out — where the fade-out is the fade-in mirrored
across the clip's center, hand-tuned once instead of matched twice.

**Shape (unresolved — this is a marker note, not a blueprints):**
- Rides the generic keyframe store (TODO.md: Active 3): a per-key flag
  (`mirrored: bool`? or a mode on the track) that makes the sampler fold its
  value across the clip's center: key at offset `o` implies a virtual boundary
  key at `len(o) = clip_len - o`.
- Open questions for later:
  - Does the ghost mirror the VALUE (v / max−v), the slot only, or both? The
    overlay fade wants value-mirroring (0 at both ends, peak at center) —
    but a position-mirror (same value, walked across = M/W-ish motion) is a
    different, also-plausible reading. Probably two flags, or one flag + rule.
  - Tied to what: clip length at edit time, or a live mirror still faithful
    when the clip is trimmed? Trim/split remapping (kf) currently rewrites
    frames — a mirrored key must survive that or recompute from its sibling.
  - Does the ghost key render as a distinct diamond in the gutter, editable
    in its own right, or is it read-only until the real key moves?
  - Interaction with interpolation modes (interp is per-key, left key owns the
    segment): a mirrored pair shares the reflected mode/curve or not?
- Parked until the mirror semantics (value vs slot) and the trim behavior are
  decided.
