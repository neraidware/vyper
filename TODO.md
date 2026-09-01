# nered Implementation Plan

## Implementation Status

Implemented (current milestone — real-time composed preview):

- **Project model** (not "file"): the app edits a `Project` with a name and a
  canvas resolution (`project.width` x `project.height`). The preview element's
  aspect ratio is driven by the project resolution (default 1920x1080).
- **Media bin**: loading media adds a `Media_Asset` *reference* to
  `media_assets` (id, path, kind, metadata, frame_count) — a reference, not the
  file contents. The file is streamed at decode time, never loaded whole; a
  bounded RAM frame cache exists but full per-asset caching is roadmap.
- **Single editor view**: there is no separate "open file" welcome screen. The
  app always shows the editor. When the timeline is completely empty an
  "Open file" button is rendered inside the timeline area; clicking it imports
  media (adds to the bin + auto-creates the necessary tracks/clips).
- **Left panel (info + bin)**: file/project info and the media bin list live in
  a panel to the LEFT of the preview. The preview + play controls sit to the
  right.



- In-process FFmpeg decoding via vendored bindings (`catermujo/odin-ffmpeg`,
  per-platform subpackages at `vendor/ffmpeg/`, linking system libs through the
  flake-provided `ffmpeg`). No subprocess decode.
- `decode.odin` provides `Clip_Decoder` (demuxer + codec + sws scaler) with
  `decode_source_frame(dec, frame_idx)`: forward requests decode the next frame
  in place; a jump re-seeks to the keyframe before the target timestamp and
  decodes forward until `best_effort_timestamp >= target`.
- `main.odin` resolves the clip active at `playhead.frame`, opens one decoder per
  source path, decodes that clip's source frame into an RGBA `192x108` buffer,
  uploads it into a GPU texture, and draws it into the preview area via the
  sampled-texture pipeline.
- Playback advances `playhead.frame` on a 60-second monotonic clock; preview only
  re-decodes when the playhead moves.
- Preview render is flicker-free w.r.t. GPU races: the preview texture is
  double-buffered (upload into the back buffer, flip after upload, always draw
  the front), so a texture being displayed is never written while read, and the
  preview stays on screen once the first frame is available.
- Decoded frames are stored in RAM: a bounded (`FRAME_CACHE_CAPACITY` = 24)
  MRU-evicted frame cache on `Clip_Decoder` caches RGBA frames as they are
  decoded, so a frame at the playhead (and recent neighbors) are served from
  memory instead of re-decoded, reducing re-seek stalls on scrubbing.
- Audio currently renders live in real time via `audio.odin`: an
  `Audio_Clip_Decoder` decodes the active audio clip's stream in-process
  (libavcodec + libswresample -> interleaved S16 at native rate/channels) and
  an SDL3 `AudioStream` bound to the default playback device plays it. The
  stream is kept ~0.15s ahead of the playhead and resyncs on play/seek/load.
  (Current limitation: plays the first active audio clip; overlapping-audio
  mixing is roadmap.)
- `Clip` now carries `path` so each clip references its original source file
  (per TODO Data Model).
- On import, the file is probed in-process (`probe_streams` in decode.odin) to
  count video and audio streams; a video track plus one `Audio N` track per audio
  stream are created. Audio clips carry `kind = .Audio`, `stream_index`, and
  render in a distinct `AUDIO_CLIP` color; video-clip resolution for the preview
  skips audio clips. (Actual audio decoding/playback still pending.)
- Verified end-to-end at runtime with a generated mp4: open -> find stream ->
  codec open -> seek -> flush -> forward decode -> timestamp match -> sws RGBA.

Not yet implemented (roadmap below):

- **Right-click "Import media" context menu** in the timeline: should trigger the
  same import flow as the empty-timeline button (add to bin + auto-create
  tracks), available at any time, not only when the timeline is empty.
- **Drag assets from the bin to the timeline** to place clips (bin is currently
  only a list of loaded file references; clips are auto-created on import).
- **Clip properties menu** (per-clip: trim in/out, speed, source offset, etc.).
- **Resolution-driven compositing**: the preview internally stays 768x432
  (16:9) for now; a non-16:9 project fits the frame with letterbox bars. Properly
  scaling the composite to an arbitrary project resolution (reallocated buffers
  or GPU-level scaling) is not yet implemented.
- **The filename extension-based filter**: ffprobe still shells out (see below),
  and import happens through one path; a bin entry is currently only created
  together with auto-created clips.
- Per-asset decoder cache (decoder reuse across clips; multiple clips referencing
  one source). The RAM frame cache on a single decoder is done; sharing one
  decoder + pool across clips is not.
- Decode off the render thread (async worker), so a slow decode never stalls the
  frame loop.
- Multi-track/multi-clip composition and blending (currently renders the single
  active clip at the playhead).
- Overlapping-audio clip mixing (currently plays the first active audio clip).
- Audio clock as the master clock (currently audio is fed ahead of the 60fps
  video playhead).
- VFR-exact frame selection (currently timestamp-targeted via average frame rate).
- Export pipeline.
- Nix `packages.default` derivation: blocked because the vendored static libs
  (`clay-odin/linux/clay.a`, stb's `stb_truetype.a`) are not present in the
  `src = ./.` snapshot. Dev shell build (`nix develop --command odin build .`)
  works. Fix by filtering source to keep binaries or building those libs in the
  derivation.

## Backlog (planned, in order)

### NEXT REQUEST — Playback/timeline quality regression + audio scrubbing

Reported: playback, timeline interaction, clip-transition rendering, and
scrubbing have all degraded. Fix this regressed core before any new features.
These are the highest-priority items and should be the next work block:

- **Playback quality regression**: playing shows wrong/stale frames, dropped or
  desynced content, and generally feels bad. Re-baseline playhead advancement,
  the dropped-frame preview path (`update_preview_slots` frontier logic), and A/V
  sync after the recent clip-identity/invalidation/decode changes.
- **Timeline interaction regression**: clicking/selecting/editing clips on the
  timeline behaves poorly (verify clip hit-testing, selection identity by
  `clip_id`, drag, and the boundary glue after the raw-delete + drag-back flush
  bug fixes).
- **Clip-transition rendering**: the boundary between two adjacent (flush) clips
  is wrong — wrong frame shown at the seam (the lost-region bug). The
  cache-desync guard fixed one path; audit the remaining no-gap-boundary seam
  holistically and confirm the wrong-image cannot recur.
- **Scrubbing regression**: scrubbing the playhead over the timeline is janky /
  shows wrong frames. Verify the persistent-decoder cache + seek behavior under
  rapid non-monotonic playhead moves.
- **Audio scrubbing not implemented**: the playhead scrubs video but audio does
  NOT follow the playhead while scrubbing (only on play start/stop/resync). When
  the user drags the playhead, audio must seek to the scrubbed position and play
  from there. Requires hooking `audio_seek`/the producer resync into the scrub
  (mouse drag + auto catch-up) path in the UI.

Verification for this block: `NERED_CACHE_PROBE`, `NERED_FRAME_PROBE`, and
`NERED_BOUNDARY_PROBE` all at 0 mismatches; interactive scrub/play across a
no-gap clip boundary renders the correct frame and audio follows the playhead.

- **Pitch-preserving playback rate**: playback >1x currently uses
  `SDL_SetAudioStreamFrequencyRatio` (plain resample), so **pitch rises** at
  2x+. Recommended approach (user-approved, not started): FFmpeg
  `libavfilter` **`atempo`** time-stretch (WSOLA) applied to the final **post-mix
  PCM** before it reaches the device, with the device left at 1x
  (`SetAudioStreamFrequencyRatio` = 1.0). This keeps tone at source pitch while
  advancing `rate`x through source content. Requirements/constraints:
  - Persistent `atempo` filter graph per producer session (it is streaming
    stateful), fed post-`audio_mix_frame`, with an output FIFO between the filter
    and `PutAudioStreamData`.
  - `atempo` only accepts `0.5..2.0`, so **chain** two filters for 3x/4x
    (atempo=2.0 + atempo=2.0), and re-provision the chain when `playback_rate`
    changes. Chain differs by rate, so tear down + rebuild the graph on rate
    change (coalesced like the resync path).
  - Must dispose the graph (avfilter_graph_free) on `audio_reset_play` /
    shutdown to avoid leaking frames/state.
  - Bookkeeping: mixing stays content-frame-driven (`audio_play_frame`); atempo
    shrinks the fed sample count by 1/rate. Queue-depth (`max_queue`,
    `queued_frames`) reporting must account for the post-mix rate change or the
    drift/drain telemetry (`dev_ratio`) misreads.
  - Requires linking `libavfilter` (`-lavfilter` in the extra linker flags)
    and importing the vendored `vendor/ffmpeg/avfilter` package.
  - Quality note: WSOLA atempo is high quality for music/speech at 1.5-2x;
    expect some artifact at 4x (inherent to fast time-stretch). Backward playback
    stays video-only regardless (no reverse audio in scope).

### NEXT — Clip resizing (shorten / lengthen)

Timeline clip resize: drag a clip's left/right edge to shorten or lengthen it.

- **Right-edge resize**: change `source_length_frames` (trim tail / extend).
  Lengthening is capped by source frames available after `source_start_frame`
  (need the source total, via `Media_Asset.frame_count` for `asset_id`).
- **Left-edge resize**: move `source_start_frame` AND `timeline_start_frame`
  together (anchor the right edge); lengthening backward capped by source frames
  before `source_start_frame`. Clips on the same track must never overlap a
  neighbor.
- **Generator (Text) clips**: no source frame cap yet — a synthetic clip can grow
  freely (length is its only extent) until bounded by a neighbor.
- Interaction: edge-grab area on the selected clip, cursor change on hover, drag
  applies live. Selection/clip_id identity must follow the edit.
- **TODO: Time warping (deferred)**: eventually a clip's playback speed can be
  rescaled independently of its timeline length (a 1s clip stretched to 2s plays
  at half speed). This step only shortens/elongates — changing timeline length
  with a fixed source frame budget (trim) — no speed change yet.

- **Preview render-safe area**: clip image must never render outside the final
  project canvas area (the black view rectangle). Currently content is clipped
  only to the whole preview widget; a clip dragged off-canvas paints over the
  letterbox/GUI area around the canvas. Clip content scissor = canvas view ∩
  widget bounds; selection border/handles stay clipped to the widget so handles
  on off-canvas boxes remain grabbable.
- **Clip slicing**: press `S` (no repeats, not while typing in a property field)
  splits the clip under the playhead at the playhead frame. Right half is a new
  clip with shifted `source_start_frame`/`timeline_start_frame`; both halves keep
  their in-range clip markers. Split audio and video clips alike.
- **Adjacent-clip visuals**: when two clips on the same track touch exactly
  (end == next start), each clip keeps its rounded corners + top/bottom/left
  borders but drops the shared right/left border; the intersection is drawn as a
  thin 1px divider line (the untouched neighbor's border). Non-touching clips
  keep current visuals.
- **Clip markers**: markers live directly on the `Clip` (`markers:
  [dynamic]Clip_Marker`, `source_frame` + label), drawn as a tiny downward
  triangle at the top of the clip tile. Survive slicing (each half keeps
  in-range markers) and timeline moves (they move with the clip).
- **OBS hybrid MP4 chapter import**: OBS writes chapter markers as a QTFF `text`
  track (`hdlr` handler `text`, "OBS Chapter Handler", `stsd` entry `text`) which
  FFmpeg demuxes as a `MOV_TEXT` subtitle stream. On import, collect that
  stream's packets, convert each PTS (text stream time base) to a source frame
  via the video stream's average frame rate, strip the QTFF 2-byte length
  prefix/padding, and attach the results to the video clip as markers.
- **Project start/end (render range)**: define the area of the project that will
  actually be rendered to a file when export lands. `I` hotkey sets the start,
  `O` sets the end. Visually a range rectangle sits just below the timeline
  ruler bar. Default is unset start/end = the whole project. Setting start and
  end to the same frame clears the range. Persist as project fields
  (`project_in/out` frames, unset = full project).
- **No auto-fit on import**: importing a video larger than the project canvas
  must NOT auto-adapt it to fill the canvas. Drop the fixed automatic
  scale-to-fit behavior; the clip imports at its native size and the user
  transforms (scale/position/crop) it themselves afterwards. Revisit the
  resolution/scale defaults set at import time (`import_media` in media.odin:
  inferred canvas size, `scale = 1`, transform centered).

## Current Architecture

- Odin owns application state, UI layout, timeline state, input, and rendering orchestration.
- Clay owns declarative layout, hit testing, scrolling, clipping, and render-command generation.
- SDL3 owns window creation, input events, Vulkan-backed GPU device setup, swapchain acquisition, and command submission.
- SDL GPU renders Clay rectangle and border commands with an SDF shader.
- stb_truetype provides initial monospace glyph rasterization and GPU atlas text rendering.
- xdg-desktop-portal is accessed through direct Odin GIO/GDBus bindings for file selection.
- FFmpeg command-line probing currently supplies metadata only. It must not remain playback infrastructure.

## Data Model

### Project

- Store project name, canvas width, and canvas height (resolution).
- Project resolution drives the preview element's aspect ratio.
- The app edits one project; opening media goes into the project's media bin.

### Media Asset (bin entry)

- A reference to a loaded file (path + metadata), NOT the file contents.
- Media assets are streamed at decode time; no full-file load into memory.
- See below for the existing asset fields.

- Store immutable source URI/path.
- Store media kind: video, audio, image, or other supported media.
- Store container format, duration, dimensions, stream metadata, and frame-rate metadata.
- Store one stable asset identifier so multiple clips can reference the same source.
- Keep source metadata separate from timeline edits.

### Clip

- Store reference to source media asset.
- Store source start frame.
- Store source end frame or source length.
- Store timeline start frame.
- Derive timeline end frame from timeline start plus clip length.
- Store track-local ordering and optional layer/order information.
- Keep all placement and trimming data on clip, never on track.
- Moving a clip changes only timeline start/end values.
- Trimming changes source range and therefore clip duration, without changing source asset.

### Track

- Store stable track identifier and user-visible name.
- Store unlimited clips.
- Store media policy: video, audio, mixed, or future specialized track types.
- Store ordering/layer index used by compositor.
- Never store clip position outside clip objects.

### Timeline

- Store unlimited ordered tracks.
- Store total duration derived from clip extents.
- Store current playhead frame.
- Store playback state: stopped, playing, paused, or seeking.
- Store timeline frame rate/timebase for UI and playback scheduling.
- Resolve all clips active at a playhead frame.

## File Import

- Open media files through xdg-desktop-portal FileChooser.OpenFile.
- Keep media filters limited to supported media extensions and MIME types.
- Convert returned file URI to local path.
- Probe selected asset with FFmpeg libraries, not a shell command, once bindings exist.
- Validate that at least one supported audio, video, or image stream exists.
- Add one Media Asset (bin entry, a reference) to `media_assets` on import.
- Auto-create the necessary tracks/clips on the timeline (video track + one
  Audio N track per audio stream), each clip referencing the imported asset.
- Import is reachable from the empty-timeline "Open file" button; later also via
  a right-click "Import media" context menu (same flow).
- Reset playhead to frame zero when creating the initial clip.

## FFmpeg Library Layer

- Add Odin bindings for libavformat, libavcodec, libavutil, libswscale, and libswresample as needed.
- Link FFmpeg libraries through flake.nix.
- Implement explicit error conversion from AVERROR values to Odin strings.
- Open input format contexts from asset paths.
- Find best video/audio streams and create codec contexts.
- Copy codec parameters into decoder contexts.
- Handle codec send/receive state correctly.
- Handle packets, flush packets, end-of-file, corrupt packets, and decoder errors.
- Use stream time bases and frame timestamps instead of assuming constant FPS.
- Preserve timestamps for variable-frame-rate media.
- Convert decoded pixel formats to compositor format with libswscale.
- Convert decoded audio formats with libswresample when audio preview is added.

## Decoder Cache

- Maintain one decoder state per active source asset.
- Reuse decoder state for sequential playback.
- Seek decoder only when playhead jumps, clip changes, or direction changes.
- Flush codec buffers after every seek.
- Seek to a keyframe before requested source frame.
- Decode forward until requested presentation timestamp is reached.
- Cache a small bounded number of decoded video frames per asset.
- Never cache unbounded decoded frames.
- Release decoder state when assets are no longer referenced by timeline clips.

## Timeline Compositor

- At each playhead frame, resolve every active clip from every track.
- Calculate source frame/time:
  `source_position = source_start + playhead - timeline_start`.
- Ignore clips before timeline start or after timeline end.
- Decode each active video clip at its calculated source timestamp.
- Composite tracks in track order, with later tracks above earlier tracks.
- Define behavior for gaps: transparent/black video and silence for audio.
- Define behavior for overlapping clips explicitly.
- Convert all active video frames into one common preview pixel format.
- Composite into one bounded 192x108 preview buffer initially.
- Keep compositor output independent from source decoder buffers.
- Support arbitrary clip positions without changing source media.

## Playback Clock

- Playhead is the only authority for current timeline position.
- Use a monotonic high-resolution clock.
- Advance playhead using timeline timebase, not render-loop iterations.
- Preserve source timestamps for VFR clips during decoder selection.
- Pause freezes playhead and compositor output.
- Resume continues from exact playhead frame/time.
- Stop at timeline duration or configured loop boundary.
- Seeking updates playhead immediately and requests decoder repositioning.
- Drop late preview frames rather than growing queues.

## Preview Output

- Preview displays only compositor output, never a source file directly.
- Create one GPU texture for the composed 192x108 BGRA/RGBA frame.
- Upload only the latest completed compositor frame.
- Use a bounded producer/consumer queue between compositor and render thread.
- Do not allocate one texture per frame.
- Do not write decoded frames to disk.
- Keep preview texture upload on the render thread if SDL GPU requires it.
- Render preview texture inside the bordered preview area.
- Preview click controls timeline playhead playback state.

## Timeline UI

- Keep `Timeline` as the parent model for tracks.
- Keep `TracksSection` responsible for track rows and labels.
- Keep `ClipsSection` responsible only for positioned clips.
- Track labels stay outside horizontal clip scrolling.
- Clip lane width is determined by its panel; clip content may overflow and scroll.
- Clip width is one pixel per timeline frame at zoom 1.
- Add timeline horizontal scroll offset independently from clip positions.
- Render playhead at `timeline frame * zoom` within clips lane.
- Playhead marker remains independent from normal clip flow layout.
- Dragging a clip updates its own timeline start/end frame.
- Add collision/overlap policy later; initial version allows free overlap.
- Add track creation/deletion later.

## GPU Rendering

- Keep SDL3 GPU Vulkan backend explicit.
- Keep rounded rectangles implemented by fragment SDF, not CPU rings.
- Render borders using outer and inner SDF distances.
- Keep rectangle uniforms aligned to std140 layout.
- Render glyph atlas through a dedicated sampled-texture pipeline.
- Render composed preview through a dedicated sampled-texture pipeline.
- Cache pipelines, samplers, textures, and buffers for application lifetime.
- Recreate swapchain-dependent resources on resize.
- Add validation/debug labels around command recording.

## Text

- Keep stb_truetype for initial ASCII UI text.
- Select configured monospace font through Fontconfig.
- Bake glyph atlas once per font size.
- Cache atlas GPU texture and sampler.
- Render Clay text commands as GPU glyph quads.
- Add UTF-8 decoding before expanding beyond ASCII.
- Add HarfBuzz only when complex shaping is required.

## Audio Preview

- Add audio stream selection during asset probing.
- Decode audio through libavcodec.
- Resample through libswresample.
- Feed bounded PCM queue to SDL3 audio device.
- Synchronize audio clock and video playhead.
- Define behavior when no audio stream exists.

## Export

- Keep export separate from preview compositor.
- Reuse asset/clip/timeline model.
- Build FFmpeg output graph from timeline state.
- Avoid temporary frame files.
- Stream encoded output directly to destination.
- Report progress and cancellation.

## Resource and Failure Handling

- Close format and codec contexts on every failure path.
- Release packets, frames, GPU textures, samplers, pipelines, and transfer buffers.
- Bound all queues and caches.
- Surface unsupported codecs and malformed files in UI.
- Handle missing portal service gracefully.
- Handle Vulkan/device/swapchain loss and resize.
- Never block UI thread on full-file decoding.

## Verification

- `odin check .` after every subsystem change.
- `nix develop --command odin build .` for reproducible builds.
- Validate shaders with `glslangValidator`.
- Test CFR and VFR videos.
- Test audio-only and image assets.
- Test multiple clips referencing one source.
- Test overlapping clips on one track.
- Test clips on multiple tracks.
- Test clip movement, gaps, overlaps, seeking, pause, resume, and resize.
- Test files with spaces, Unicode, and apostrophes in paths.
- Test cancellation and decoder errors.
