# vyper TODO

## Active — Unicode text + GPU glyph cache (full font coverage)

**Status:** UI text (`render_text`) bakes a fixed 512px atlas of 95 ASCII
chars at 32px and loops bytes, so `é` (and any non-ASCII) is dropped both by
the byte-loop clamp and the missing atlas entry. Text clips/subtitles are
**already Unicode-safe** (`textclip.odin` iterates runes via
`stb.MakeCodepointBitmap`) — no work there. Input already routes composed
UTF-8 through `SDL_StartTextInput` + `.TEXT_INPUT` (event.odin:116); `é`
reaches the buffer, it just never renders. Goal: cache every glyph the font
provides, GPU-side, on demand.

Design decisions (from 2026-09-12 review):
- **Dynamic growable atlas**, R8, bake-at-32px keeping the current
  `scale = fontSize/32` model (UI sizes are 11–18px, so 32px bake is
  sharp). Fixed 48px cells (4px bleed), grid doubles 16→32→64 cells/side
  (1024→2048→4096px).
- **Flat direct-index `rune_map[0x110000]u32`** (4.4MB session-heap block,
  single allocation) instead of a hash map — O(1) lookup, no hot-path
  hashing. `slots` grow-only array, cap 4096, zero value = unused.
- **Deferred baking**: `render_text` runs mid-render-pass, cannot start a
  GPU copy pass. Missing glyph → record in pending list (coalesced per
  frame), skip quad that frame. Pre-swapchain in `render_ui_frame`
  (frame.odin, after thumbnail uploads, before AcquireSwapchainTexture)
  bake + upload only dirty cells via region copy.
- **Grow = re-create texture 2x, re-bake all cached runes into it** (no
   9MB CPU pixel mirror retained; re-bake is CPU-cheap, measure with
   spall — one-time ~ms hitch on a rare event).
- ASCII 0x20–0x7E prebaked in `upload_font_atlas` replacement.
- Combining marks overlay naturally (zero-advance quads) — no shaping. Full
  harfbuzz shaping is a separate future task, explicitly out of scope here.
- Unsupported runes (e.g. emoji the face lacks) blank this phase; tofu box
  is a later polish item.

Steps (each lands + passes probe + vet before the next):
- [ ] S1. CPU core in `gpu_renderer.odin`: `Glyph_Atlas` struct (texture/
      sampler, cells_x/y, generation, `rune_map`, `slots`, pending/dirty
      lists) + slot allocator + cell-grid placement + `glyph_ensure(rune)`
      doing metrics-only bake (advance/bbox via `stbtt_GetCodepointHMetrics`
      + `GetCodepointBitmapBox`, no pixels yet). Extend `ui_probe` (rename
      the ASCII-only assertion at ui_probe.odin:69) or add a CPU-only
      `font_probe` covering: slot allocation, cell layout on grid growth,
      rune dedup, rune_map round-trip.
- [ ] S2. `render_text` (gpu_draw.odin:758) iterates runes via `utf8`
      decode over `chars[0:length]`; draws from slot metrics+UV; missing
      glyph → queue pending + skip. Delete the byte clamp and the
      `stb.GetBakedQuad`/`renderer.font.chars[95]` call sites.
- [ ] S3. `input_advance_up_to` (gpu_draw.odin:387) decodes runes and sums
      cached advances so caret/selection track non-ASCII text.
- [ ] S4. Deferred bake + upload in `render_ui_frame`: CPU-bake pending
      glyphs, assign cells, upload dirty cells via copy pass (no render
      pass open there), grow on capacity. Remove fixed 512 atlas
      (`Font_Atlas` → `Glyph_Atlas`, `upload_font_atlas` → prebake ASCII +
      dynamic path).
- [ ] S5. `measure_text` (font.odin:58) counts runes, not bytes, for the
      0.55/character layout estimate (optional later: exact stbtt advance).
- [ ] S6. Input verification: probe confirms a composed `é` via
      `text_input_insert` renders a non-empty glyph; lifecycle polish —
      `SDL_StartTextInput`/`StopTextInput` scoped to when a field is open
      (so IME never eats global hotkeys); `.TEXT_EDITING` (IME preedit)
      optional in a later pass.
- [ ] ACCEPT: type `é`, `Й`, `ω`, `日本` in the rename popup and each
      renders glyph-true and moves the caret correctly; no per-frame
      allocation (temp allocator only for bake scratch); spall trace shows
      glyph bake+upload outside the hot frame path; probes + `-vet` green.

Out of scope (future): harfbuzz shaping, color/emoji glyphs, tofu box,
per-size-bucket baking for >32px UI text, IME preedit UI, exact-advance
text measurement for layout.

## Phase 1 — Performance, Cleanup, Refactoring, Polish

- Proxy lag: decode cost grows monotonically within a segment (file-position
  dependent), resets at segment boundary when decoder reopens. Root cause and
  fix remaining open.
- Proxy cache directory: move proxies out of source dir into
  `$XDG_CACHE_HOME/vyper/proxies` keyed by stable source-path hash.
- Per-asset decoder cache: share one decoder + pool across clips referencing
  the same source; current RAM frame cache exists but decoders are per-clip.
- Hardware decode + encode for proxies (NVENC / AMF / VA-API / VideoToolbox):
  detect at runtime, pick best available, fall back to libx264-ultrafast.
  Near-real-time proxy builds with near-zero CPU on supported hardware.
- `nice`/low-priority ffmpeg on POSIX so capped software encode yields to
  interaction on small-core machines.
- Proxy re-encode on project resolution change.
- Codebase cleanup: bare layout constants (z-index stacking 300/1000/2000/
  2001/3000) promoted to named constants.
- Pitch-preserving playback rate via FFmpeg `atempo` post-mix time-stretch
  (WSOLA), chained for rates >2x. Requires linking libavfilter.
- Project persistence: save/load project file format (name, resolution, fps,
  render range, export presets).
- Overlapping-audio clip mixing (currently plays first active audio clip only).
- Audio clock as master clock.
- VFR-exact frame selection (currently timestamp-targeted via average frame rate).
- `odin check .` clean — zero warnings baseline for every change.

## Phase 2 — UX Overhaul

- Resolution-driven compositing: scale composite to arbitrary project
  resolution (reallocated buffers or GPU-level scaling), not just 768x432
  letterboxed.
- Custom resolution entry (arbitrary WxH field, not just presets).
- Frame rate presets in the Project Info panel + custom fps entry.
- Aspect-ratio presets / orientation model (16:9, 9:16, 1:1, 4:3, 21:9, custom).
- Mid-project resolution change semantics: how existing clips handle canvas
  resize (transforms, proxies, preview pipeline).
- Clip properties menu (trim in/out, speed, source offset, etc.).
- Right-click "Import media" context menu (available at any time).
- Drag assets from bin to timeline to place clips.
- Export pipeline (codecs, rate control, HW encoders, container, progress).
- Template presets ("YouTube 1080p60", "Instagram Reels 9:16 30fps").

## Phase 3 — Node-Based Compositor + Compositor Window

Node-based composited clips system with a dedicated compositor window.
Details TBD when Phase 2 reaches maturity.

## Implemented (current state)

- **Project model**: edits a `Project` with name + canvas resolution driving
  the preview aspect ratio (default 1920x1080).
- **Media bin**: `Media_Asset` references (path, kind, metadata, frame_count)
  streamed at decode time, never loaded whole.
- **Single editor view**: no welcome screen; empty timeline shows "Open file".
- **Left panel (info + bin)**: file/project info + media bin; preview + play
  controls to the right.
- In-process FFmpeg decoding via vendored bindings (`catermujo/odin-ffmpeg`).
- `Clip_Decoder` (demuxer + codec + sws scaler) with `decode_source_frame`.
- Async decode off render thread (`4a8d8ae`): dedicated SDL thread per clip,
  latest-wins semantics, honored by preview proxy.
- Double-buffered GPU preview texture (flicker-free).
- Bounded MRU frame cache (`FRAME_CACHE_CAPACITY=24`).
- Audio: live real-time rendering via `Audio_Clip_Decoder` + SDL3 AudioStream,
  ~0.15s ahead of playhead, resyncs on play/seek/load.
- `Clip` carries `path`; media probing done in-process (`probe_streams`).
- Auto-created tracks/clips on import (video track + Audio N per audio stream).
- Preview proxies: segmented all-intra (`-g 1`, 900-frame segments), low-res
  (768x432), transcoded at import, `proxy_pick_for_frame` resolves per-frame.
- Clip resize: left/right edge drag for trim/extend, clamped to source bounds.
- Clip slicing (`S` key): splits at playhead, both halves keep in-range markers.
- Adjacent-clip visuals: shared-border divider, rounded corners preserved.
- Clip markers (`Clip_Marker`, `source_frame` + label): survive slicing.
- OBS hybrid MP4 chapter import (QTFF `text` track → markers).
- Project start/end render range (`I`/`O` hotkeys).
- No auto-fit on import: native size, user transforms manually.
- Subtitle generator clip (.srt): context menu → file picker → parsed cues,
  center-anchored box, cue-change resizes, static snapshot v1.
- Building clay + nanosvg from vendored source at build time (no prebuilt binaries).
