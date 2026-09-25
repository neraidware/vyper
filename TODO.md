# vyper TODO

## Pending (2026-09-18)

- [ ] **Windows import segfault** — reported by user, not reproduced on Linux
      (no Windows host). Candidate defect: `portal_windows.odin`'s persistent
      path buffers `win32_picked_path: [1024]byte` (line 22) and
      `win32_save_picked_path` (line 103) — the `copy(dst, path_utf8)` result
      `n` is then used as `buf[n] = 0`, so a picked UTF-8 path >= 1024 bytes
      writes one past the buffer. Unconfirmed as the real crash. Need:
      `vyper_crash.log` (exception code + fault address) and the `[win-ff]`
      DLL-majors line, or a Windows repro. Note: the CI smoke test
      (`VYPER_PROXY_PROBE`, decode + proxy) passes on Windows, so the common
      probe/thumbnail/proxy import path is healthy — the picker path is not
      exercised by CI.
- [ ] **CI artifact upload vs quota** — Windows workflow `.github/workflows/
      windows.yml` upload step. The account artifact quota filled (3.18 GB /
      43 `nered-windows` artifacts, all <= 2026-09-11); cleared them via the
      API and set `retention-days: 7` (`2998b3c`). Uploads still fail until
      GitHub recalculates usage (every 6-12h). Decide: `continue-on-error:
      true` on the upload step (recommended) or gate the upload to tags/manual
      dispatch, so a quota hiccup can't red a green build + smoke. Build and
      smoke pass; only the upload fails the job.

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

**Status:** implemented — dynamic GPU glyph atlas covers the full font face; UI text
(`render_text`) walks runes and bakes glyphs on demand, non-ASCII (`é`, `Й`, `ω`,
`日本`) renders and the caret advances by character. Confirmed in code 2026-09-25;
the TODO's unchecked boxes were stale. S6's lifecycle polish is now also done
(SDL text input scoped per edit session, `textinput.odin`).

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
- [x] S1. CPU core in `gpu_renderer.odin`: `Glyph_Atlas` struct (texture/
      sampler, cells_x/y, generation, `rune_map`, `slots`, pending/dirty
      lists) + slot allocator + cell-grid placement + `glyph_ensure(rune)`
      doing metrics-only bake (advance/bbox via `stbtt_GetCodepointHMetrics`
      + `GetCodepointBitmapBox`, no pixels yet). Extend `ui_probe` (rename
      the ASCII-only assertion at ui_probe.odin:69) or add a CPU-only
      `font_probe` covering: slot allocation, cell layout on grid growth,
      rune dedup, rune_map round-trip.
- [x] S2. `render_text` (gpu_draw.odin:986) iterates runes via `utf8`
      decode over `chars[0:length]`; draws from slot metrics+UV; missing
      glyph → queue pending + skip. Delete the byte clamp and the
      `stb.GetBakedQuad`/`renderer.font.chars[95]` call sites.
- [x] S3. `input_advance_up_to` (gpu_draw.odin:456) decodes runes and sums
      cached advances so caret/selection track non-ASCII text.
- [x] S4. Deferred bake + upload in `render_ui_frame`: CPU-bake pending
      glyphs, assign cells, upload dirty cells via copy pass (no render
      pass open there), grow on capacity. Remove fixed 512 atlas
      (`Font_Atlas` → `Glyph_Atlas`, `upload_font_atlas` → prebake ASCII +
      dynamic path).
- [x] S5. `measure_text` (font.odin:58) counts runes, not bytes, for the
      0.55/character layout estimate (optional later: exact stbtt advance).
- [x] S6. Input verification: probe confirms a composed `é` via
      `text_input_insert` renders a non-empty glyph; lifecycle polish —
      `SDL_StartTextInput`/`StopTextInput` scoped to when a field is open
      (so IME never eats global hotkeys) — landed 2026-09-25
      (`text_input_begin` turns text input on, commit/cancel turn it off);
      `.TEXT_EDITING` (IME preedit) optional in a later pass.
- [x] ACCEPT: type `é`, `Й`, `ω`, `日本` in the rename popup and each
      renders glyph-true and moves the caret correctly; no per-frame
      allocation (temp allocator only for bake scratch); spall trace shows
      glyph bake+upload outside the hot frame path; probes + `-vet` green.

Out of scope (future): harfbuzz shaping, color/emoji glyphs, tofu box,
per-size-bucket baking for >32px UI text, IME preedit UI, exact-advance
text measurement for layout.

## Active 3 — Generic keyframing system (keyframe timelines, decoupled)

**Why:** animate/automate any scalar clip property (transform, scale, gain,
crop, ...) from the timeline itself. Unlike a first-feature hack, the model is
property-agnostic: any closed set of scalar properties can ride it, and the
automation-lane system later adopts it whole (IDEAs.md:150 blueprints the
property-id-addressed shape). S1–S4 build the system alone; S5 (below) wires it
into playback/preview.

**Model (decoupled, Godot-style) — GENERIC, uncoupled from clip properties:**
- `Keyframe { frame_off: i32, value: f32 }` — frame **relative to the clip's
  start** (the keyframe timeline is clip-relative; moving the clip moves its
  rows). A keyframe deals with exactly **ONE value**; multiple values →
  multiple keyframe tracks.
- `Kf_Track { name: string, keys: [dynamic]Keyframe }` sorted by
  `frame_off`. Nothing property-shaped in the store: **the system never
  interprets `name`** — it is an opaque id + the gutter label, minted by the
  consumer (e.g. the gain field writes the track named "gain"). The
  name→property mapping lives in the consumer that wires values, not here, so
  anything listable can ride it (pixels, dB, scale fractions, a future property
  `Clip` doesn't even carry yet). A row exists only when its track has >= 1
  key; a clip with no keys keeps today's layout.
- **Linear between keys; direct control outside them** (per user): a key
  applies ITS value on its own frame (creating/editing a keyframe is visible
  immediately); between two adjacent keys the value interpolates linearly and
  reaches the NEXT key's value **exactly on that key's frame**. Before the
  first key and past the last key the property is INACTIVE — the caller keeps
  its own `base`/resting value, so direct field edits and canvas drags apply
  there (editing a transform after the last key works even though a key
  exists). Exact numbers pinned by probe.
- `kf_sample_for(clip, name, timeline_frame, base)` — generic; callers stay
  property-unaware.
- **Ownership:** track names are cloned at creation; every clone site
  (clone_timeline, duplicate_track/clip) deep-copies them; split/trim remaps and
  free_timeline free what they replace. Untouched/edit sites keep the shared
  marker-style convention.

**Clip transform semantics (for the wiring follow-up):**
- `scale` is relative to the clip's **original source proportions**, not to
  the canvas. A clip at scale 1 keeps its native aspect box; scaling up from
  there never fights where it sits on the canvas (today it's canvas-relative,
  so the same value letterboxes differently per project resolution).
- New `zoom` property: upscales **only the clip's content, never the bounding
  box** — a magnification at the same box, so a camera-style zoom stays fluid
  (no box/layout math during the move). Distinct from `scale` (box) and `crop`
  (insets the edges): zoom keeps the box and the aspect untouched.

**Timeline UI (the "keyframe timelines"):**
- Keyframes render in a **dedicated row below their assigned clip**, spanning the
  clip's extent. "Piano sheet" per-value lines: each keyframed value gets its
  own line.
- Tracks gutter: the **property name**, stacked under the track name.
- A keyframe = a **45°-rotated rectangle (diamond), 1 px border, neutral
  background, light when selected** (use the rect-rotation path built for the
  gain-knob needle).
- Track row height grows to fit the tallest keyframed clip
  (`CLIP_TILE_HEIGHT + rows x row_h`). A collapse toggle is a later option —
  **not** this slice.
- No property consumption in S1–S4: storage + render + selection + editing +
  eval proc only. Wiring (Scale into preview, Gain into the live fold) landed in
  S5 below.

**Selection:**
- **Cannot select a clip and a keyframe at the same time** — mutually exclusive.
  Selecting a diamond deselects clips (`selected_track = -1`, clear
  `selected_set`); selecting a clip clears the keyframe selection.
- A selected keyframe shows its value in the inspector.

**Interaction / editing:**
- **Add keyframe: click the diamond button next to the property field** in the
  inspector → records the field's current value at the playhead, creates the
  row on first key. The buttons paint as keyframe diamonds (`draw_kf_add_buttons`,
  the exact KF_DIAMOND_* look scaled via KF_BTN_R); Shift+click was retired.
- Drag a diamond horizontally → moves its `frame_off` (clamped 0..clip length).
  A no-move click must not reseek/reset anything (the clip-stutter lesson).
- `Delete` removes the selected keyframe. **Discrete commit per add/move/delete
  on the undo seam**; `clone_timeline` deep-copies tracks (undo snapshots).
- Split remap on a keyframed clip — Slice-1 rule (user): left keeps keys `< F`,
  right half re-relatives (`- F`), values preserved. Implemented with the S1
  structural paths (every clip-copy/free site must own keyframes, or a shared
  backing dangles on the next key edit): split_clip, ripple straddle/trims,
  duplicates, delete paths, clone/free.

**Steps** (each lands + probe + vet before the next):
- [x] S1. Data model: `Keyframe` / `Kf_Track` (name-opaque) /
      `Clip.keyframe_tracks` + store helpers, incl. the linear eval
      (`kf_sample` / `kf_sample_for`) pinned by probe;
      `clone_timeline`/`free_timeline`, duplicates, delete paths, and the
      split/trim remaps all own keyframes; `VYPER_KEYFRAME_PROBE` green.
      (No property wired into playback/preview anywhere — decision #3 holds
      for the whole slice; the row itself is the demo.)
- [x] S2. Render: growable track-row height + gutter property labels + diamond
      draw (45° rect, 1 px border, neutral fill, light when selected). Row grows
      per `KF_ROW_H` lane (a clip's keyframe tracks), clip tile is wrapped so
      it grows DOWNWARD with one lane per track, gutter stacks a label line per
      lane, `timeline_tracks_content_height` sums per-track lanes, diamonds are
      the rotated-SDF overlay `draw_keyframes` (scissored per track), and
      `VYPER_UI_PROBE` seeds a two-track keyframed clip and asserts the grown
      row/tile/gutter geometry. Selected-fill color (KF_DIAMOND_FILL_SELECTED)
      is defined but the light state lands with the S3 selection.
- [x] S3. Selection + inspector: exclusive keyframe/clip selection; keyframe
      value field. `Keyframe_Selection` (state.odin) is index-keyed to the
      live tree with a `kf_structure_gen` guard (bumped by set/del/split/trim)
      so a shifted key can never alias a reused slot; `kf_select` clears the
      clip selection, `select_clip`/clip-press clear the keyframe, `kf_selected`
      bounds+gen-checks every resolve. Click hit-tests diamonds via the shared
      `kf_key_center` geometry (`draw_keyframes` and the hit-test use one
      source of truth), and the Clip inspector swaps to a keyframe readout
      (prop name, absolute frame, editable value field) while a diamond is
      selected — value edits commit through `edit_commit` as a `.Value` undo
      node. `undo_restore`/media import drop the selection (indices can't
      survive a wholesale tree swap). Verified by `VYPER_UNDO_PROBE` (S3
      section: exclusivity both ways, value-edit add/undo/redo, gen
      invalidation) — probes + `-vet` green.
- [x] S4. Interaction: diamond "add keyframe" button beside each property field
      adds a key; drag diamond to move; Delete removes; undo commits. Add = the
      KfAdd* buttons (ui.odin, `kf_add_button`, hit by `interaction.odin`), each
      calling `kf_add_prop` (main.odin): minting the track name is the CONSUMER's
      job — the X/Y/Scale/crop/gain buttons call `kf_add_prop(sel, "transform.x"..., value)`
      and it records the field's current value at the playhead (clip-relative,
      clamped), as one `.Value` node. The buttons paint as the exact keyframe
      diamond (gpu_draw.odin `draw_kf_add_buttons`, KF_DIAMOND_* look via
      KF_BTN_R, hover lifts the fill). Diamond drag = new `Interaction.Keyframe_Move`:
      the same press that selects (S3) arms it, `update_keyframe_drag` slides the
      key with the pointer (frame derived straight from the wrap box — the exact
      inverse of `kf_key_center`'s cx mapping, so the diamond never detaches), and
      `commit_keyframe_drag` on release commits only when the frame actually
      moved — normalized as a pure store pair del(old)+set(new) so the track
      stays sorted and unique from wherever the drag landed (the no-move click
      reselects and leaves state untouched — the clip-stutter rule). Backspace/
      Delete hit `delete_selected_keyframe()` when a diamond is selected, else
      fall through to the clip delete. Verified by `VYPER_UNDO_PROBE` (S4
      section: add/move/delete round-trips, move-is-a-move not a copy, no-op
      drag off the undo trail, delete fallthrough) — probes + `-vet` green.
- [x] ACCEPT: the diamond button adds a row under the clip showing the diamond; dragging
      moves it; selection flips between clip and keyframe exclusively; all edits
      clean on undo/redo; probes + `-vet` green.
- [x] S5. Functional wiring (the Active-3 "follow-up"); keyframes are now
      CONSUMED. Preview: `update_preview_slots` samples `transform.x/y`, `scale`,
      `crop.l/r/t/b` at the playhead into the slot (`kf_sample_for`), so keyed
      clips animate live on the canvas while the clip's fields keep their
      resting base; un-keyed properties sample base exactly — the render is
      unchanged for every existing project. Audio: `audio_geometry_commit`
      snapshots the clip's `gain` track FLAT into each chip
      (`GAIN_KF_MAX_KEYS`, overflow truncated + logged once), provision copies
      it into the `Play_Seg`, and `audio_mix_frame` re-evaluates the keyed gain
      per mixed timeline frame via `kf_sample_keys(seg.kf_keys, frame -
      seg.start_a, ...)` — the producer never reads the live timeline, it
      samples its own copy. `kf_sample`/`kf_sample_keys` share one algorithm
      (linear between keys, resting base outside them — since the S5 sanity
      fix, the `step` move-toward model was dropped for linear, and the
      after-last-key region rules resting so direct edits apply);
      probe pins their agreement + clip-relative addressing. Export now evaluates
      keyed geometry per frame through `render_eval_keyed_geom`; its current
      max-scale/full-box resampling path needs the performance follow-up in
      Active 4.

## Active 4 — Export keyframe compositor performance

**Status:** measured 2026-09-25. Export scale keyframes are functional but
pathologically expensive; transform- and crop-only keyframes do not reproduce
the regression. Scope is export rendering. Preview behavior is unchanged.

**Measured baseline (60 frames, CPU encoder, deterministic fixtures):**
- 1280x720: no-key export ~0.45 s wall; scale `1 -> 3` ~3.51 s. Keyed `sws`
  ~52.9 ms/frame; stage grows to 3840x2160.
- 1920x1080: no-key export ~0.81 s wall; scale `1 -> 3` ~7.78 s. Keyed `sws`
  ~119.3 ms/frame; stage grows to 5760x3240.
- Static scale `3` stays near baseline because the static path applies a
  visibility crop. Keyed clips currently skip that crop and resample the full
  max-scale stage before canvas clipping.

**Root cause:** keyed setup in `render_worker_run` sizes stages from the maximum
keyed scale (`render.odin:2043-2083`). `render_eval_keyed_geom` then runs
`sws.scale` over the full stage/current box every frame
(`render.odin:2687-2717`), while `render_blit_region` clips only afterward.
The producer timing labelled `codec` includes `scale_decoded_frame`; its jump
is stage scaling, not primarily decoder seeking. Off-canvas pixels and a
one-frame maximum key therefore inflate both producer and compositor work.

**Implementation order (each step lands with probe + vet before next):**
- [ ] S1. Add an opt-in headless export benchmark fixture for scale `1 -> 2`,
      `1 -> 3`, constant scale, transform-only, crop-only, reversed scale, and
      off-canvas motion. Record wall time, producer time, keyed `sws`, stage
      dimensions, output frame count, and a reference-frame hash/PSNR.
- [ ] S2. Clip keyed `sws` work to the current canvas intersection. Map the
      visible destination rectangle back to the stage source rectangle, clamp
      rounding at stage bounds, and blit only the visible result. Preserve
      transform, crop, reversed interpolation, and partial off-canvas cases.
      This is the lowest-risk first fix; probe showed ~3.5 s -> ~1.1 s at 720p
      and ~7.8 s -> ~2.4 s at 1080p.
- [ ] S3. Compute one visibility envelope per keyed clip at render start: union
      of all on-canvas source regions over the clip's sampled poses, including
      crop insets. Use that envelope to configure the decoder crop/stage once;
      never recompute allocations or decoder geometry per frame. Fall back to
      the full stage when the envelope is not safely bounded.
- [ ] S4. Size keyed decode stages from the visibility envelope rather than the
      maximum key scale. Keep enough resolution for the largest visible output,
      size double buffers and `kres_scratch` from actual maximum destination
      dimensions, and preserve source aspect/crop semantics. Compare output
      against the current path before accepting native-stage fallback.
- [ ] S5. Treat a scale track with no actual value variation as fixed scale;
      route it through the static visibility-crop path. Do not apply this to
      genuinely moving clips. Keep transform/crop-only keyed clips on a bounded
      stage path rather than max-scale full-frame decode.
- [ ] S6. Reuse or cache `SwsContext` only after S2-S5; profile first. Context
      creation measured ~0.2-0.5 ms/frame, so it is secondary to eliminating
      wasted pixels.
- [ ] ACCEPT: 720p and 1080p scale `1 -> 3` exports stay within 2x of their
      no-key baselines; no off-canvas full-box resampling; no per-frame
      allocations; output frame count/duration and reference pixels remain
      correct. `VYPER_KEYFRAME_PROBE`, `VYPER_RENDER_KF_PROBE`,
      `VYPER_UNDO_PROBE`, `VYPER_DRAG_PROBE`, `VYPER_TL_PROBE`,
      `VYPER_UI_PROBE`, `VYPER_TRANSFORM_PROBE`, `odin check`, and a fresh
      compositor spall trace all pass.

**Out of scope:** preview keyframe sampling, encoder changes, and GPU compositor
rewrite. Fix export geometry work first.

## Queued — Performance / Cleanup

- **Consolidate top-level mutable globals into named state structs** — the
  globals namespace is polluted with ~140 top-level vars. Three clean groups,
  each to fold behind one owner, in order of payoff:
  1. **UI per-frame scratch text buffers** (`ui.odin:31-49`, ~11 buffers like
     `UI_TEXT_STATE`, `UI_TEXT_RULER`, `UI_TEXT_OUT`). Each is used inside a
     single proc; today they share index space with real state. Fold each into
     the one proc/struct that writes it (a HUD row struct). Small, safe, no
     behavior change.
  2. **Encoder identity globals** — `proxy.odin` encoder constants/version and
     `clip_id_seed` (media.odin:220). Group into a `Proxy_Encoder` /
     `Clip_Id` struct so cache-key derivation lives with its inputs.
  3. **Audio state block** — `audio.odin:340-652` (~15 mutables: audio_play_frame,
     audio_jump_frame, audio_provisioning, audio_play_frame, audio_report_*,
     audio_silence_holes, audio_geom_overflow…). Fold into one `Audio_State`
     struct owned by the audio thread. Largest refactor; do last.

  Rule of thumb: a top-level `: var` that isn't config, a scratch buffer, or a
  seed belongs in the struct of the subsystem that owns its lifetime.

- **HW-encode tail is cadence-sensitive (the last GOP)** — with byte-identical
  composite input (verified via per-frame canvas dump), the h264 VA-API tail
  frames (last 4 of ~240) render differently depending on compositor pacing:
  the full-canvas mem.zero skip shifted composite 1.14 -> 0.99 ms/f and the
  *tail* of the exported file changed while the canvas input did not (both
  builds also show their own tail artifact: base froze the final frames ~4 late,
  skip kept "motion" past a frozen clip end; no frame-shift alignment exists).
  Same binary = deterministic output; any code-path/cadence change = new tail.
  Suspect the encoder's async EOF drain (`render_enc_flush` / drain-on-stop)
  racing packet delivery. Fix: make the tail cadence-independent (flush until
  the decoder returns consistent last-frame content) or pin encoder pacing;
  otherwise a cadence-only change can non-deterministically alter the last GOP
  of an export.
- **GPU-side encode (NOT planned)** — Export is CPU-pipeline-bound; the
  encoder thread is the gate at 3.74 ms/f for 240x1080p60 (RGB->NV12 SIMD
  1.87 + VAAPI surface upload 1.03 + h264_vaapi 0.84), everything else
  (producer 1.97, composite+audio 2.20) sits under it. The only meaningful
  remaining win is removing that conversion+upload from the encoder thread
  via Vulkan<->VAAPI dma-buf interop (VK_EXT_external_memory_dma_buf ->
  prime fd into the VAAPI surface). Risky/hard: FFmpeg's vaapi encode path
  always copies sw frames into its own surfaces, so raw-VAAPI or forked
  send is involved; NVIDIA would be CUDA-only (this box is Intel). Floor if
  it works ~1.18s -> ~0.7s (240f). Decided against for now. If ever picked
  up, start with a 2-3 day spike: render one NV12 frame into a dma-buf,
  import it into a VAAPI surface, check whether iHD encodes it without a
  copy; only proceed on a pass.
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
- **Export encoder defaults to hardware (GPU), software = fallback** — GPU
  encoding officially confirmed faster than libx264 by a large margin
  (1080p60 export wall 1.13s vs 1.68s CPU, ~33% end-to-end; encoder thread
  ~2.4 vs ~5.5 ms/f). Default is `h264_nvenc → h264_vaapi → h264_qsv →
  h264_amf → libx264`, so software runs only when no hardware encoder opens.
  Manual "High quality (CPU)" still available in the encoder menu.