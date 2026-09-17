# vyper TODO

## Active 1 — Optimized playback pipeline: hw decode, in-process ffmpeg, true-rate preview

**Why:** mpv plays 2x AV1 1080p60 pitch-preserved, smooth, full quality on this
machine. We can't: our decoder is pure software (`avcodec.open2(ctx, codec, nil)`,
decode.odin:355 — no `hw_device_ctx` anywhere), AV1 1080p60 software decode is
one of the most expensive loop-carried jobs a CPU does and 2x doubles the per-
wall-second decode load while the background proxy build software-encodes on top.
We also never show the original: `proxy_pick_for_frame` serves the 768x432 proxy,
so full quality is unreachable by design and host decode power goes unused.
Audio speed is `SetAudioStreamFrequencyRatio` (audio.odin:347) — plain resampling,
tape-style pitch shift. mpv pitch-preserves via WSOLA.

**Core rule — no more ffmpeg binaries. Ever.** All ffmpeg/ffprobe shell-outs
(import_bg.odin:552 encode, proxy.odin:165 frame-count probe, media.odin:49/81
probes) become in-process calls into the vendored libav* bindings we already link
for decode. No `process_start`, no `-progress` file, no PATH dependency.

Design decisions (from 2026-09-14 review):
- **HW decode**: `AVHWDeviceType` per platform (VA-API/Vulkan on Linux, D3D11,
  VideoToolbox), best `hw_pix_fmt` chosen at open, `av_hwframe_transfer_data` to
  a staging buffer for the existing texture-upload path (v1; GPU→GPU v2).
- **Software fallback is measured, not assumed**: open with a performant default,
  sample decode throughput against source rate at first enable; if the host can't
  sustain >= source fps in real time, drop to proxy preview. Per-asset, re-tested
  when the decoder setup changes.
- **Preview the ORIGINAL, GPU-scaled, when the host keeps up** — the mpv path.
  Proxy-window build (`proxy_build_schedule`) becomes the weak-host fallback and
  stays for export/render reuse.
- **Encode in-process**: segment/whole proxy transcode via `avcodec` (x264) + mux
  via `avformat`. Verify each artifact by opening it in-process (avformat read +
  frame count) — deletes the ffprobe verification round-trip that just produced
  a silent `-1` on a fresh segment in the scheduler probe run.
- **Pitch-preserving rate**: link `libavfilter`; `atempo` (WSOLA) one stage per
  rate <=2, chained for >2x, inserted into the audio producer. Audio clock as
  master clock for sync at rate (0/Auto = 1.0).
- Probe/CI determinism keeps: probes must still pass offline; `odin build -vet`
  clean baseline unchanged.

Steps (each lands + probe + vet before the next):
- [x] S1. In-process probe+verify: add `avfmt`-based `in_proc_frame_count(path)`
      (read packets, count video frames) and replace the `ffprobe` shell-outs in
      `proxy_probe_frame_count` (proxy.odin:162), `probe_video_size` +
      `probe_media` (media.odin:46/80). Probe: frame counts match ffprobe on a
      known file; the `-1` case now reports a reason, not code=1 empty.
      DONE 2026-09-14 (`first_video_packet_count`, `probe_video_dimensions`,
      in-process `probe_media` blob keeps key=value contract). Also fixed the
      sched probe's non-NUL-terminated env path string (root cause of the
      original ENOENT + seg-`-1` bug) and its consume-before-read waits;
      `VYPER_PROXY_SCHED_TEST` + bg + tl probes all green.
- [x] S2. In-process proxy encode: segment encode via `avcodec` libx264 +
      `avformat` muxer mirroring the current argv (all-intra, `-g 1`, 900-frame
      segs, scale via `swscale` with libx264 ultrafast/fastdecode/crf=26,
      threads). Worker loop gains no subprocess; segment progress = encoded
      frames counter (`on_frames`/`cancelled` callbacks). Opening frame of each
      segment lands on the exact source index via the keyframe-backward seek +
      PTS walk (bounded by one GOP) that `decode_source_frame` uses; a VFR
      overshoot encodes the held frame and queues the overshot one. Cancelled
      out-of-segment kills the encode mid-flight (32-frame poll). Verified v1:
      bg-test builds a full window (tiny + med120, incl. cancel-at-35%) with
      artifacts byte-identical coverage (frame counts), `VYPER_PROXY_SCHED_TEST`
      green (incl. far-jump retarget + cancel → Done_Cancelled + on-disk 0+2
      coverage), tl probe green, libx264 / libav INFO chatter silenced via
      `avutil.log_set_level(.Error)`.
- [x] S3. Delete the subprocess encode path + ffprobe/fc-less imports that remain:
      `subprocess.odin` stripped to just `run_capture`/`resolve_tool_argv` for
      fontconfig's `fc-match` (Linux only); `ffmpeg_argv_from_command`,
      `discard_stderr` removed; stale ffmpeg-subprocess comments neutralized
      throughout `import_bg.odin`, `proxy.odin`. No `run_capture` of
      ffmpeg/ffprobe left; no `"ffmpeg"`/`"ffprobe"` string literals remain in
      the binary. Vet clean.
- [x] S4. HW decode in `Clip_Decoder`: enumerate the codec's hw configs
      (`get_hw_config`) for one with an `HW_Device_Ctx` method, create the
      device (`hwdevice_ctx_create`), attach it via `hw_device_ctx`; the decoder
      negotiates hw frames automatically. Each hw frame is pulled to software
      with `av_hwframe_transfer_data` (+ `frame_copy_props`/`frame_move_ref`)
      before the existing sws path, so the PTS walk, hold, and cache logic never
      see device memory. sws is built lazily from the first transferred frame's
      format (VAAPI -> NV12), since `sw_pix_fmt` is unset for QSV/VAAPI export.
      Software path stays byte-identical; `VYPER_HW_DISABLE=1` forces it and
      `VYPER_HW_PROBE="<file>|<count>|<stride>"` decodes the same frames both
      ways; deviceless/unsupported hosts fall back clean (probe still passes).
      Probing on this host: h264 1080p vaapi vs sw 0 mismatches (and a modest
      ~12% wall gain on the 891-frame forward pass); av1 ran sw-sw parity at
      first because `find_decoder` returns libdav1d (sw-only) for AV1 by id —
      corrected later via `find_hw_decoder` resolving the native 'av1' decoder
      which does carry VAAPI (see note at ACCEPT, 2026-09-16).
- [x] S5. Original-rate preview: when decoder throughput sustains source fps,
      `proxy_pick_for_frame` resolves the original path (decode from original,
      GPU-or-sws scale to canvas). Deadline: one CPU core of air left on a
      1080p60 playback. Gate: `playhead.playing && playback_dir == 1` plus the
      physical decoder's `hw_pix_fmt != .None` (worker's own flag published
      atomically for the front slot; per-slot decoder for background). On
      switch: one reopen + seek to the new keyframe, then steady forward
      decode at source fps. `VYPER_RATE_PROBE="<file>|<max_frames>"` confirms
      the deadline on any host: 14% cpu util on med120 1080p30 (hw vaapi) =
      one core of air, pass criterion `decode_ms < duration_ms / 2`.
- [x] S6. Pitch-preserving rate: `atempo` in former of audio producer; rate
      dropdown (ui.odin:1486) pitch-preserves at 1.5/2 (and chords >2). Probe:
      tempo up does not shift a tone's pitch; sync holds at 2x for 30s.
      (`VYPER_ATEMPO_PROBE=ALL` green: 440 Hz tone stays 440 at every rate,
      out = in/rate balance within 3%; graph bypass at 1.0x; rate > 2 chains
      atempo=2.0 stages multiplicatively + remainder stage.)
- [ ] ACCEPT: 2x AV1 1080p60 plays smooth, pitch preserved, full-res, cores free;
      re-check mpv does no better. Weak-host fallback still builds windowed
      proxies via in-process encode. No `"ffmpeg"`/`"ffprobe"` strings in the
      binary. Probes + vet green.
      NOTE (2026-09-16): two playback blockers fixed since the last probe.
      Audio self-heal fired on the in-flight provision's transient zero-count
      and re-provisioned every ~200ms (re-open storm, 282 resyncs/83s on the
      7.8GB source) — fixed by 801026f, gating on `audio_provisioning`.
      Hardware AV1 decode was dead in-process: `find_decoder(AV1)` returns
      libdav1d (registered first, sw-only) so the native 'av1' decoder with
      the usable VAAPI config was never chosen; 7c193e5 adds `find_hw_decoder`
      backing both playback decode and proxy_encode_range. Verified:
      AV1 hw vs sw pixel-identical (mismatches=0), proxy bg-build hw-decodes
      per segment, seek-forward soak at 2x holds pace with resync=3 and
      proxy-build CPU footprint 274%->151%.
      2x soak (2026-09-16, post-fix): 65s AV1 at VYPER_RATE=2, 20 content-s:
      resync=3, holes=0, pace=ok, ~120fps (2x of 60), source decoded via
      vaapi hw (pixfmt 44), process CPU ~20% during playback (frac of one
      core — cores free). GUI confirm + mpv recheck still outstanding.

Out of scope (future): GPU→GPU zero-copy compositing, hw-encode for proxies,
ICC color management, video interpolation (motion-estimated), A/V drift autotune.

Open bug (shelved, resolved by S2): scheduler probe reported fresh
segments verifying as `-1` (ffprobe code=1 empty stderr) while bg-test passes
same file — subprocess-post-encode verification fragility; gone with
in-process encode+verify (probe is now a file handle open, decode-200, close).

## Active 2 — Unicode text + GPU glyph cache (full font coverage)

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

## Queued — Performance / Cleanup

- Proxy cache directory: move proxies out of source dir into
  `$XDG_CACHE_HOME/vyper/proxies` keyed by stable source-path hash.
- Per-asset decoder cache: share one decoder + pool across clips referencing
  the same source; current RAM frame cache exists but decoders are per-clip.
- HW encode for proxies (NVENC / AMF / VA-API / VideoToolbox): detect at
  runtime, pick best available, fall back to libx264-ultrafast.
- Proxy re-encode on project resolution change.
- Codebase cleanup: bare layout constants (z-index stacking 300/1000/2000/
  2001/3000) promoted to named constants.
- VFR-exact frame selection (currently timestamp-targeted via average frame rate).
- Overlapping-audio clip mixing (currently plays first active audio clip only).
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
  ~0.15s ahead of playhead, resyncs on play/seek/load. Speed control is
  resample-only (pitch shifts — the atempo/WSOLA fix is Active 1 S6).
- `Clip` carries `path`; media probing done in-process (`probe_streams`).
- Auto-created tracks/clips on import (video track + Audio N per audio stream).
- Preview proxies: segmented all-intra (`-g 1`, 900-frame segments), low-res
  (768x432), transcoded at import, `proxy_pick_for_frame` resolves per-frame.
- On-demand playhead-window proxy building (segment margin around playhead,
  far-jump redefine, cancel suppression; `VYPER_PROXY_SCHED_TEST` probe).
- Import progress: non-blocking corner badge with cancel (was a modal veil).
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