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
  frame loop. **Done** (`4a8d8ae`): the foreground clip decodes on a dedicated
  SDL thread (latest-wins), honored by the preview proxy; probes that step the
  playhead run the worker deterministically.
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

### Project settings / canvas configuration

Single place for everything a `Project` can be configured with. The Project Info
panel (left sidebar) is the always-visible home for these controls.

Status: **resolution + orientation are done** — the resolution preset buttons
(Auto / 720p / 1080p / 4K) and the orientation toggle (portrait vs landscape)
live in the Project Info panel and work at any time, empty timeline or not. The
old empty-state settings panel now only holds the frame-rate presets.

Planned, in detail:

- **Frame rate in the info panel**: presets 24/25/30/48/60/Auto already exist
  (`fps_preset_button`) but only render in the empty-timeline Project Settings
  panel, so they are unreachable once the timeline has clips. Move them into the
  Project Info panel next to resolution; the click handlers in `main.odin` are
  still gated on `len(timeline.tracks) == 0`. Also allow a **custom** frame rate
  (arbitrary number, not just presets). Remap considerations on change: timeline
  grid, playhead cadence, audio producer (see `set_project_fps`), and any audio
  that is already queued (resync path).
- **Custom resolution entry**: an arbitrary WxH field (not just the presets),
  with validation, replacing the current preset-only buttons. Dimensions drive
  the canvas aspect ratio and the preview fit.
- **Aspect-ratio presets / orientation model**: today orientation is just a
  width/height swap (`vertical_toggle_button` + `set_project_orientation`).
  Richer model wanted: aspect presets (16:9, 9:16, 1:1, 4:3, 21:9, custom) that
  pick resolution pair from a base dimension, plus a separate explicit
  pixel-aspect-ratio field. Orientation should survive resolution changes
  (currently Auto + swap can fight: buttons re-arm when `resolution_locked`
  flips).
- **Mid-project resolution change semantics**: what happens to existing timeline
  clips when the canvas resizes?
  - Clip transforms (`transform_x/y`, `scale`): keep pixel-relative values
    (anchored) or rescale proportionally? Decide + document.
  - Preview proxies are encoded at a fixed low resolution (`proxy_transcode`);
    a canvas shrink/grow may need proxy re-encode or acceptable GPU up/down
    scale until rebuilt. Currently proxies are per-source, not per-project, so
    this affects the preview pipeline (`draw_preview`, `preview_transform`).
  - Letterboxing for non-canvas-aspect source material.
- **Render/export codecs and settings** (all future, none implemented):
  - Video codec choice: H.264, HEVC/H.265, AV1, ProRes, (Motion JPEG?), with
    per-codec option sets (profile, level, tune) surfaced only when the codec is
    selected.
  - Rate control: constant vs constrained vs target bitrate, CRF/quality slider,
    GOP/keyframe interval, max-bitrate, buffer size, multi-pass.
  - Hardware encoders: NVENC / AMF / VA-API / VideoToolbox where available
    (detect at runtime; fall back to software x264/265).
  - Pixel format / color range (`yuv420p`, `yuv444p`, limited vs full range),
    color space primaries/transfer/metadata (Rec.709, Rec.2020, PQ/HLG for HDR),
    tonemapping on export.
  - Audio codec: AAC, Opus, MP3, PCM/WAV (FLAC) + sample rate + channel layout;
    audio sample-rate conversion at export, not at import.
  - Container: MP4, MOV, MKV; chapter markers (see OBS chapter import) embedded
    on export when present.
  - Encoder presets/speed vs quality tradeoff, and a "fast rough cut" vs "final"
    mode.
- **Other project info / metadata**:
  - Project name editing (currently read-only text).
  - Template presets that set several fields at once (e.g. "YouTube 1080p60",
    "Instagram Reels 9:16 30fps") as a quick-start in the info panel.
  - Defaults for new/empty projects (start resolution, fps).
  - Color management workspace choice (sRGB / Rec.709 / Rec.2020 / HDR) driving
    both preview and export, once compositing supports it.
  - Track-level settings worth exposing later (per-track mute/solo/lock/opacity)
    are out of scope for the project-info panel; they belong to the track
    headers.
- **Project persistence**: none today — everything is in-memory, so none of the
  above survives a restart. On the roadmap: a project-file format
  (`project.name`, `width/height`, `frame_rate`, in/out render range, and later
  export/render presets) with save/load, so settings live in `Project` struct +
  disk, not in UI globals.

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
  rapid non-monotonic playhead moves. **Fluidity addressed** (sessions `fe8ed1e`
  → `4a8d8ae`): low-res all-intra preview proxies transcoded at import (render
  keeps the original), decimated exact-frame decodes during a drag
  (`SCRUB_DECIMATION`, cheap when release lands on an already-decoded face), and
  the async worker for the foreground clip. The remaining wrong-frame/stale-frame
  audit at no-gap boundaries is still open.
- **Audio scrubbing not implemented**: the playhead scrubs video but audio does
  NOT follow the playhead while scrubbing (only on play start/stop/resync). When
  the user drags the playhead, audio must seek to the scrubbed position and play
  from there. Requires hooking `audio_seek`/the producer resync into the scrub
  (mouse drag + auto catch-up) path in the UI.

Verification for this block: `NERED_CACHE_PROBE`, `NERED_FRAME_PROBE`, and
`NERED_BOUNDARY_PROBE` all at 0 mismatches; interactive scrub/play across a
no-gap clip boundary renders the correct frame and audio follows the playhead.

### Proxy recode speed / background-builder responsiveness

The background proxy builder (`import_bg.odin`) transcodes a large source to a
768x432 all-intra preview. Done so far:

- **`-preset ultrafast`** (was `veryfast`) in BOTH the background builder and
  the synchronous `proxy_transcode` path: ~1.8x faster encode on a 10-min
  1080p test source with the same `-crf 18` output quality, settings still in
  lockstep between the two builders.
- **`-threads` capped to half the logical cores** (`proxy_encode_threads`,
  `sdl.GetNumLogicalCPUCores`): a default-threaded transcode saturates every
  core (decode + x264), starving the SDL loop so the editor looks frozen while
  the worker runs. Half leaves the interactive side air; wall time barely moves
  because frame DECODE is the bottleneck, not x264.
- **Segmented (chunked/progressive) proxy**: the background builder encodes the
  proxy as independent all-intra `PROXY_SEG_FRAMES`-sized segments in
  source-time order, republishing a sidecar `.idx` after each one, so the head
  of the timeline goes proxy-fast ~1s after import while the tail still encodes
  and uncovered ranges decode the source. `proxy_pick_for_frame` resolves a
  proxy file PER SOURCE FRAME (segment / legacy whole proxy / nil); decoders
  translate source indices to each file's local timebase and reopen on a
  physical-file switch. Cancel keeps completed segments and only drops the
  in-flight one.

Remaining (real lever for hours-long sources):

- **Hardware decode + encode** (NVENC / AMD AMF / VA-API / VideoToolbox): detect
  the encoder at runtime from `ffmpeg -encoders` (already enumerated; this dev
  box has none usable — no render node/CUDA), pick `h264_nvenc` /
  `h264_videotoolbox` / `h264_vaapi` / `h264_qsv` / `h264_amf` / fallback
  libx264-ultrafast, and mirror the input side with `-hwaccel` decode
  (decode-bound when the source is huge). Expect near-real-time proxy builds
  with near-zero CPU. Encoder-specific quality args (`-cq`/`-qp`, `-g 1`,
  `-bf 0`) must keep both builders in lockstep and still pass the frame-count
  parity check + decode-content probe.
- **`nice`/low-priority ffmpeg** on POSIX so even a capped software encode yields
  to interaction on small-core machines.
- **Proxy re-encode on project resolution change** (see mid-project resolution
  semantics above): a canvas shrink/grow may want a fresh proxy resolution.

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

### Clip resizing (shorten / lengthen) — implemented

Timeline clip resize: drag a clip's left/right edge to shorten or lengthen it.

- Implemented: right-edge drag trims/extends the tail (`source_length_frames`);
  left-edge drag trims/extends the head, moving `source_start_frame` and
  `timeline_start_frame` together so the tail stays anchored. Lengths are
  clamped to >= 1 frame, never overlap a neighbor, and never overrun the asset's
  source total (`Media_Asset.frame_count`), so lengthening can undo a shorten but
  not exceed the media's end. Text/generator clips (no source cap) grow freely.
  Edge hover shows the horizontal-resize cursor + an accent bar on the edge.
- **TODO: Time warping (deferred)**: eventually a clip's playback speed can be
  rescaled independently of its timeline length (a 1s clip stretched to 2s plays
  at half speed). This step only shortens/elongates — changing timeline length
  within a fixed source frame budget (trim) — no speed change yet.

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

### Subtitle generator clip (.srt) — planned

A subtitle "generator" clip: one contiguous timeline clip that renders the SRT
file's cues as its output, in sequence. It behaves like a Kdenlive "Sequence"
made of text clips, but is simply a generator clip whose input is an `.srt`
file that we parse and rasterize ourselves. Unlike Kdenlive/Resolve (which bolt
subtitles onto a separate subtitle system), this is just another generator —
so it inherits the normal clip model: position, scale, trimming, selection,
link/duplicate/delete, and the preview/export pipelines.

**Core design (user-confirmed)**

- **Context menu entry:** a new row in the right-click "Add >" flyout, labeled
  **"Subtitle Clip (.srt)"** (user's wording: *"New subtitle clip"*). Clicking it
  **immediately opens a file picker for the `.srt` file**; only on a successful
  pick does a clip get created. Cancel → no clip.
- **Placement/geometry:** the generated text is always **centered** in the
  clip's preview bounding box. The box is sized to the *currently generated
  cue's* tight ink proportions (`source_w/h`, like text clips) and is centered
  on a user-controlled anchor (`transform_x/y`, default = canvas center). The
  user drags the box anywhere on the canvas; each cue change re-sizes the box
  to that cue's proportions while the box stays centered on the anchor. This
  satisfies "the next generated text is centered relative to the bounding box
  which is always relative to the currently generated text."
- **Timing:** cue timings are **relative to the clip's start** (sequence
  semantics) — cue at `t` seconds fires at `clip_start + round(t*fps)`. Moving
  the clip moves all its cues.
- **Trimmable:** edge-drag crop works; cues outside the trimmed window are
  skipped (a range check in the lookup).
- **Styling v1:** none. Raw, centered, white text with the normal transform
  handles. Alignment/background/color/outline are explicitly LATER.
- **SRT reactivity:** **static snapshot** — parse once at clip creation. No
  mtime watching in v1; an explicit "Reload subtitles" action is later.

**Data model**

- `Generator_Kind` grows `.Subtitles` (beside `.Text`); the clip keeps
  `kind = .Text` (rendered like text) or a new `Media_Kind.Subtitle` — decide
  at implementation. Mirror how `.Text` clips are authored in
  `add_text_generator_clip` (new `add_subtitle_generator_clip(track, start)`).
- `clip.path` = absolute `.srt` path (cstring, clone-on-duplicate, freed on
  delete — mirror the file-backed clip lifecycle).
- `clip.name` = display label only (basename of the srt). **Crucially, unlike
  the text generator, `name` is NOT the rendered text** — the preview/render
  paths must branch on `generator` (`.Subtitles` ⇒ look up the active cue),
  never on kind alone.
- `source_start_frame`/`source_length_frames`: relative cue-frame window; the
  clip's length defaults to the full SRT span. Trimming edits this window.
- No media-bin asset entry in v1: the srt is a generator *input*, not media.
  (Revisit if users want it listed.)

**SRT parsing — new `srt.odin`**

- Parse blocks separated by blank lines: numeric index (ignored), an
  `HH:MM:SS,mmm --> HH:MM:SS,mmm` range, then one or more text lines.
- Tolerate CRLF, a leading BOM, trailing blank lines, and malformed blocks
  (skip + warn, keep going). Parse timestamps to **milliseconds**; convert to
  frames **on demand** at the project fps (fps can change → recompute, never
  re-parse). `round(ms/1000*fps)`.
- Produce `[]Srt_Cue { start_ms, end_ms, text, lines: [dynamic]string }`
  (split on `\n`). Offsets: first cue's start defines relative frame 0? No —
  cues are absolute srt times; relative = cue_time − srt_start is NOT applied
  unless the user trimmed the head. Keep v1 semantics: clip start == srt 0:00;
  cues play per their stamps, clipped by the clip window.
- **Shared cache:** one parsed-cue array per srt path, reference-counted by the
  clips that reference it (`srt_load(path) -> ^Shared_Srt`, unref on clip
  delete). Same cache feeds preview + export, split by nothing — it is
  read-only after load.
- UTF-8: text may be non-ASCII; the rasterizer already iterates runes and the
  atlas path is rune-based — verify a ≥128 non-ASCII codepoint end-to-end and
  note shaping limits (no Arabic/Indic shaping; FFmpeg/UI text is monospace).

**Context menu + picker**

- Add `ctx_option("CtxSubtitleClip", "Subtitle Clip (.srt)")` beside
  `CtxTextClip` in the Add flyout (ui.odin `draw_context_menu`).
- Dispatch in `handle_ctx_option` (main.odin): call the srt picker **before**
  closing the menu. On a path: parse → create clip on `ctx_menu.target_track`
  at `ctx_menu.frame` with length = full srt span → select it. On parse
  failure: leave an error surface (status line / toast) and create nothing.
- Picker: extend `open_file_picker()` with an optional filter, or add a second
  portal proc; the portal call currently hardcodes a media-extension filter
  tuple (portal.odin `portal_open_file_picker`) — build a `'*.srt'`-only filter
  for this call, and a matching Win32 `.srt` filter. Guard: silently accept a
  non-srt too (portal pickers ignore filters), parse + error if invalid.

**Preview rendering (UI thread — preview_state.odin slots)**

- For a `.Subtitles` clip slot: at each update, `rel = playhead.frame -
  clip.timeline_start_frame`; pick the active cue (binary search over cue
  start frames, intersection check with the trimmed window). No cue →
  transparent slot (nothing drawn), like a gap.
- Rerasterize **only when the cue's cache key changes** (cue text hash,
  `text_clip_hash`, + `font_px = 48*scale`) — same stale-detection pattern the
  text clip already uses, but the key is the *active cue* not `clip.name`.
- Cache the last N cue rasters per slot (v1: 1; bump to a small LRU so
  scrubbing back-and-forth doesn't reraster every crossing) — this is the
  "cache the generated text outputs" requirement.
- On cue change: re-measure base tight dims at font 48 → update
  `clip.source_w/h` (the box that drives the handle/transform math re-sizes
  automatically). Raster at `48*scale` for crispness, exactly like text clips.
- Center-anchored box: existing preview math treats `transform_x/y` as the
  top-left; subtitle boxes need center anchoring (`box.x = anchor.x - box.w/2`,
  etc.). Handle/drag code in preview_transform must move the anchor (center) and
  scale about the center; verify handle grabbing above/below the text still
  works when the box is smaller than the text's ink (take the box, not the ink,
  as the grab target).
- **Multi-line, v1 (simplest):** render each line of a cue stacked vertically
  (≈1.2× font line advance), centered horizontally, composited into one buffer
  — split the rasterize helper into "one line into a sub-buffer" reuse, or add
  a multi-line variant that calls the existing single-line core per line.
  **No word wrap in v1** (a long single line overflows the box width — accepted
  for now).
- **LATER (recommended, not now):** word-wrap long single lines at ≈75% of
  canvas width; text-align (left/center/right); optional background box;
  font color + outline; explicit "Reload subtitles" + mtime watch.

**Export rendering (render worker — render.odin)**

- Snapshots: for a `.Subtitles` clip, the `Render_Text_Src` equivalent must
  carry the **shared cue array copy** (or path + a worker-side parse), relative
  start, fps, transforms, and `scale`. It is NOT the `name`.
- At render start, pre-rasterize **every cue once** into a per-cue `Render_Text_Job`
  (mirroring `setup_text_job`, same worker-owned font/scratch) — one
  `make`/raster loop, no per-frame font work. Each frame then binary-searches
  the active cue and just blits its cached raster (O(log n) per frame, zero
  rasterization during the render run). Cleanup frees all cue rasters
  (`cleanup_text_jobs` already does this shape of work).
- Multi-line cue compositing (stack + center) applies equally here; render two
  buffers only if the cue is multi-line.

**Clip interactions**

- `duplicate_clip` / `duplicate_track`: clone `path` (`strings.clone_to_cstring`),
  clone `name`, share the parsed-cue cache (**refcount up**); never deep-copy
  the cue array.
- Remove/delete: `remove_track` and the clip-delete paths must `delete(path)`
  and unref the shared srt cache.
- Split (`S`): allowed; both halves share the srt/cache; each half's window
  check crops cues. Verify the split bookkeeping (paths/clip own nothing new).
- Rename: label only; content unaffected (this is the documented split from the
  text generator, where rename edits the title).
- Timeline clip visuals: single strip colored like text/generator clips; maybe
  an `*.srt` glyph later.

**Verification**

- Existing probes stay green (`nered-probe`, transform probe).
- A test `.srt` covering: multi-cue sequencing, a cue with explicit `\n` (2–3
  lines), ms-level timestamps, non-zero first timestamp, CRLF line endings, a
  leading BOM, trailing blank lines, and a deliberately malformed block (skip + warn).
- Manual: "Add > Subtitle Clip (.srt)" → picker opens first → clip lands at the
  click frame/full length → text appears centered on the canvas → drag the box
  around, scale up (crisp at 48×scale) → scrub: each cue swaps in, box resizes
  to that cue's proportions but stays anchored → trim edges: out-of-window cues
  vanish → duplicate/delete refcount the cue cache → export renders cues
  statically correct (frame-step the output file).

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
