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
wall-second decode load while the background proxy build runs on top (it
hardware-encodes by default now, but its swscale+NV12 upload is still CPU work).
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

Out of scope (future): GPU→GPU zero-copy compositing, ICC color management,
video interpolation (motion-estimated), A/V drift autotune.

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

## Active 5 — In-app fuzzy file finder (replaces OS picker workflow)

**Why:** `:open` with no argument currently does nothing and file open/import
routes through OS-native dialog portals (portal on Linux, win32 on Windows) —
two diverging code paths, untestable cross-OS. An in-app fzf/skim-style finder
unifies file management across OSes and gives a fast, scriptable open/import
path.

**Design decisions (2026-09-26):**
- Modal popup like the cmdline popup, launched from three entry points that
  today call `open_file_picker()` / do nothing: bare `:open` command, the
  Open File button, and the Bin Import button. `open_srt_picker` (subtitle
  generator, `.srt`-only) stays on the OS picker.
- Filter text input on top reuses the generic `ti` field via a new
  `TI_FINDER` input type; the filter is cleared when a directory is entered.
- Column of rows below: generic SVG icon per file kind (folder/video/audio/
  image/subtitle/file — 6 new `Icon_Id`s, ICON_COUNT 8→14) or the media-bin
  thumbnail when the path matches an imported asset with one.
- Keyboard-first like fzf: Up/Down/Tab navigate matches, Enter descends into
  a directory or opens the selected file (commit mode: open, or import to
  bin), Esc cancels. Wheel scrolls over the popup.
- Entries listed from current directory (fzf-style browser, no recursion);
  hidden dotfiles skipped; symlinks-to-dirs followed. Filter = fuzzy match on
  basename via `cmdline_fuzzy_score`, dirs first then files.

Steps (each lands + probe + vet before the next):
- [x] S1. `file_finder.odin`: state (dir, entries, filtered indices, sel,
      scroll, commit proc), `finder_open/mode`, relist/filter/navigate/enter/
      close. `TI_FINDER` in state.odin, key routing in event.odin
      (Tab/Up/Down/Enter before `text_input_handle_key`).
- [x] S2. Icons: 6 new SVGs under icons/, `Icon_Id` members, `get_icon_svg`
      cases (rasterizer `#load`s one SVG per enum member at init — a missing
      case kills startup).
- [x] S3. Render: `draw_finder_popup` (pill + `TextInputField` caret id
      + row column) dispatched from `draw_text_input_popup`; row overdraw
      pass in frame.odin (icons via `render_icon`/`icon_box`, bin thumbs via
      `draw_tex_quad`).
- [x] S4. Routing: bare `:open` in `apply_command`, OpenFileButton,
      BinImportButton → `finder_open` with a commit proc (open_file_at /
      import_srt_to_bin / import_media_to_bin). Wheel scroll over popup.
- [x] S5. Fix: `:open` showed an EMPTY listing until the user typed something.
      `finder_refresh` memoised on the query text alone, but its output is a
      function of the query AND the entries list — so `finder_relist` (open,
      descend, go up) rebuilt the entries, cleared `filtered`, and the memo
      still claimed to be current. With an empty query (exactly the state right
      after opening) the strings compared equal and the rebuild was skipped, so
      the popup drew nothing; typing a character changed the query, forced the
      rebuild, and the list appeared. Added `filtered_valid` so the memo needs
      both inputs, set false by every relist and true by the rebuild. Note the
      probe had been papering over this with `query_len = -1` to force a scan;
      that hack is gone and the probe now builds `filtered` through the real
      `finder_refresh`. Probe: `ui_probe_finder_listing_asserts` browses a real
      directory and asserts rows appear with an empty query, both on open and
      after a relist. Mutation-checked: restoring the query-only memo fails it
      with the exact reported symptom ("79 entries but 0 rows shown").
- [ ] ACCEPT: `:open` pops the finder; navigate dirs, follow symlinks, filter
      fuzzily, open a media file and import into bin without touching an OS
      dialog. Probes + `-vet` green. (UI probe extended with a headless
      finder-layout + filter-redraw + dismiss assertion; needs a manual
      interactive pass for the final sheet.)

Out of scope (future): recursive/bookmark walking, mouse row activation,
clock-stamped recency sorting, portal/win32 picker deletion.

## Active 6 — Project files (:save / :open)

**Why:** the project is unnamed and unsaved: its identity lives only in the
live `Project` struct (coordinate-less until a media file happens to open),
and session state can't be carried across runs. A `.vyproj` file gives the
project a name, resolution, frame rate, and render range that persist, so
reopening the same media set later starts from the same canvas.

**Scope (per user, 2026-09-26):** first cut "literally just :save and :open" —
the file carried **project metadata only** (shipped as S1–S3 below). **Scope
expansion (2026-09-26, same session):** serialize what matters — media bin,
timeline tracks/clips, markers, keyframe tracks, and the srt cache — so
`:save`/`:open` round-trip the actual project content, not just its metadata.
User is the only operator, so no versioning / backward-compat machinery — the
file is recoded from `Project_File` if its shape changes.

**Design decisions (2026-09-26):**
- Format: `core:encoding/cbor`, reflection-marshaled over a plain
  `Project_File` struct (name, width, height, frame_rate, start/end_frame,
  resolution_locked) — no hand-rolled codec, no vendor.
- `:save <path>` writes the snapshot (any extension accepted by `:save`;
  `:open` dispatches on the `.vyproj` suffix), `:open <path>` routes `.vyproj`
  → project load, anything else → existing media open. Bare `:save` → usage
  notice; bare `:open` still pops the finder.
- Finders: `.Open` commit mode loads `.vyproj` the same as `:open`; `.ImportBin`
  rejects project files with a notice.
- `project.name` lifetime: starts as the literal "Untitled Project" (never
  freed); a loaded name becomes a session-heap clone tracked by
  `project_name_owned`, freed on the next load. Repeated `:open` must not
  leak or UAF.

Steps (each lands + probe + vet before the next):
- [x] S1. `project_file.odin`: `Project_File`, `project_file_save/open`, name
      ownership. cbor import confirmed in vendored Odin (no vendor needed).
- [x] S2. Wiring: `:save` token in `apply_command`, `.vyproj` dispatch in
      `:open`, finder `.Open` + `.ImportBin` routing.
- [x] S3. Probe: `ui_probe_project_file_asserts` save → reset globals → double
      open → field equality + name ownership.
- [x] S4. Path/metadata ownership (Option B). `import_media_to_bin` and
      `import_srt_to_bin` `clone_to_cstring` the incoming path into a
      session cstring the asset owns; `probe_media` returns a heap clone on the
      `unavail` literal path too. This removes the latent bug where probes store
      a STACK buffer as `asset.path` (flash_probe.odin:141, render.odin:3235) and
      makes teardown uniform — no per-asset ownership flag, because the bin
      always owns a copy. `open_file_at` no longer needs its `retained` handshake
      (callers can free their buffer unconditionally); finder/`:`/argv/autoplay
      call sites updated.
- [x] S5. `srt_cache_free_all()` + media-bin teardown proc: free each asset's
      owned path cstring + metadata clone, break the `project.info_text` alias
      first, release GPU thumbs when a renderer exists. This is the first real
      mid-process session teardown the app introduces (loading a `.vyproj`
      replaces the current session).
- [x] S6. Extend `Project_File` DTO: `Saved_Asset` / `Saved_Track` / `Saved_Clip`
      (clip `path` NOT serialized — derived from asset_id on load). Reuse live
      `Clip_Marker`, `Kf_Track`, `Srt_Source`, `Srt_Cue` (all cbor-safe).
- [x] S7. Save side: `project_to_file` snapshots media_bin (with `next_id`),
      srt_cache in order (so `srt_id` indices line up), timeline tracks/clips,
      track_order, playhead_frame, timeline frame_rate.
- [x] S8. Load side: teardown old session → rebuild bin (ids + next_id +
      re-decode thumbs) → rebuild srt_cache in order → rebuild timeline (clip
      paths from `find_asset`, clone names/markers/kf) → apply project meta →
      reset undo baseline.
- [x] S9. Probe: full session round-trip (clips, scalar + packed `[7]f32`
      keyframes, markers, srt, track_order, playhead, asset ids, next_id) and a
      second-load leak/ownership exercise (load tears down a live session twice).
- [x] S10. Marker-label ownership made real (needed by S8's teardown). Labels
      were previously immortal-shared: `clone_timeline` copied marker structs
      into undo snapshots and `filter_markers_in_range` copied them across split
      halves, so `free_timeline` could not free a label without double-freeing
      the other holder — every loaded marker leaked its label instead. Now every
      `Clip_Marker.label` is uniquely owned: `clone_marker` clones it,
      `filter_markers_in_range` and `clone_timeline` clone per copy, and all 8
      discard sites (`free_timeline`, both region-trim paths, both split paths,
      `delete_selected_clip_raw`, `remove_track`) go through `free_markers`.
      `duplicate_track`/`duplicate_clip` already deep-cloned. Valgrind: 0
      definitely lost, 0 indirectly lost, 0 invalid read/write/free.
- [x] S11. Bare `:save` opens the in-app file finder in a new `.Save` commit
      mode instead of printing a usage notice, so saving and opening share one
      picker (`:open` still opens it in `.Open`). The field is a file NAME
      rather than a filter, which changes the Enter rule: a typed name is the
      commit, an empty field keeps the row semantics (Enter on a folder still
      descends) so both navigating and naming stay on one key. The suggested
      name (`<project name>.vyproj`) is drawn as a placeholder, not field text
      — pre-filling it would make the very first Enter a save and strand the
      user in the starting directory. A name with no extension gets
      `PROJECT_FILE_EXTENSION`; an explicit extension is left alone. A failed
      save keeps the finder open so the name can be corrected; a successful one
      closes it. Fixed two leaks this path exposed: `finder_kind_of` called
      `strings.to_lower` once per listed entry per relist (now lowercased in a
      stack buffer), and `show_ui_notice` copies, so every
      `show_ui_notice(fmt.aprintf(...))` call site leaked its temporary
      (now `show_ui_noticef`, which formats in a callee-owned buffer).
      Probe: `ui_probe_finder_save_asserts` covers the mode, the unfiltered
      rows, the empty-at-open field, both extension cases, and a load-back of
      what the finder wrote.
- [ ] ACCEPT: manual pass — `:save test.vyproj`, `:open test.vyproj` shows
      "Editing <name>" and the full timeline/bin restored, bad paths give
      notices, finder open loads a project, and bare `:save` pops the finder:
      typing a name and Enter writes it in the browsed directory (with
      `.vyproj` appended when no extension was typed) while Enter on a folder
      still descends.

Out of scope (future): undo-history serialization (the baseline resets to the
loaded session), autosave, double-click-to-save, extension enforcement for
`:save <path>` (S11 only appends the extension in the finder's Save mode), and
version/format negotiation.

## Active 7 — Track context menu, compact rows, fitted divider

**Why:** the track gutter spent a 56px row on two icon buttons per track, and
duplicate/delete were the only gutter actions reachable at all. At that height
only ~10 tracks fit, and a project with more lanes opened scrolled to nothing.
Moving the actions to a right-click menu and shortening the row buys vertical
room, and an automatic fit on import/load means the lanes you just created are
on screen instead of below the fold.

**Scope (per user, 2026-09-26):** duplicate/delete move to a context menu
separate from the existing timeline menu; track row goes to 36px; importing a
clip or loading a project fits the divider to at most 5 tracks on screen.

- [x] S1. Dedicated track menu: `Track_Context_Menu`/`track_ctx`, opened by
      right-clicking the track name or the empty space in a track's clip lane
      (`track_gutter_hit_test`), drawn by `draw_track_action_menu` next to the
      existing menu. Deliberately a SEPARATE popup from `ctx_menu`, not extra
      rows on it: the track menu is a different subject, and folding it in
      would have meant the track list's `Add Track` action and a track's
      `Duplicate/Delete` sharing one enumeration whose meaning depends on what
      was clicked. The two are mutually exclusive in both directions —
      opening either closes the other — because a right-click that lands
      elsewhere must not leave two popups up.
- [x] S2. Removed the per-track buttons: the `TrackButtons` Clay subtree, the
      duplicate/remove icon overlay and its scissor pass in `gpu_draw`, and both
      click handlers in `interaction`. Hit-testing now resolves the row from the
      `TrackName` box. The `.Duplicate`/`.RemoveTrack` icons went with them
      (enum members, `ICON_COUNT`, both `icons/*.svg`) — nothing references them
      now, and a live enum member for a button that doesn't exist is a lie the
      next reader would have to chase.
- [x] S3. Compact geometry: `CLIP_TILE_HEIGHT` 56 → 36, `TRACK_GAP_H` 18 → 8,
      `KF_ROW_H` 22 → 18. The keyframe lane had to shrink with the row or a
      single-lane clip would have measured taller than a keyframed track beside
      it.
- [x] S4. `fit_timeline_to_tracks` runs at the end of `add_asset_to_timeline`
      and `session_rebuild`. It is "at most", not "exactly": the divider only
      ever moves IN, so a user whose track list already shows fewer than 5 rows
      keeps their layout and an import never yanks the divider away from a
      layout they chose. It reads the window height from `app_window` itself,
      since both callers run outside the render loop and have none to pass.
      Divider drag and the fit now share `panel_clamp_bounds` instead of
      duplicating the bounds, so the fit can't land somewhere the user can't
      drag back to.
- [x] Probe: `ui_probe_track_menu_asserts` covers the buttons no longer being
      laid out (guarded by a missing-id check so it can't pass vacuously), the
      5-row fit height, both directions of the fit, menu exclusivity, and a
      stale track target leaving the menu closed. Mutation-checked: re-adding
      `TrackButtons` and dropping the "only pull in" guard both fail the probe.
- [ ] ACCEPT: manual pass — right-click a track name gives a menu with only
      Duplicate/Delete (no Add Track), right-click empty timeline space still
      gives Add Track, the two never show at once, both actions still work, rows
      are visibly shorter, and importing a clip or opening a project with more
      than 5 tracks leaves exactly 5 visible without scrolling.

Out of scope: reordering tracks by drag, a context menu on the clip lane
(already exists), renaming a track in place.

## Active 8 — Command line opener: keycode-driven, echo matched by character

**Why:** the `:` prompt opener is a KEY_DOWN case, and one keypress produces TWO
events — the KEY_DOWN, then that same keypress's own TEXT_INPUT(":") (which
`text_input_begin` re-enables text input to receive). The prompt must start empty,
so the echo has to be suppressed. The suppression used to discard "the next text
event", so a keypress that produced no echo left it armed and it ate the user's
first real character.

**The bug was never the suppressor. It was the shape of it.** A full redesign
moved the opener to the TEXT_INPUT branch and deleted the suppressor entirely,
which was the clean design and it was WRONG: with no field open,
`text_input_cancel` has called `StopTextInput`, and SDL delivers no TEXT_INPUT at
all while text input is stopped — so a text-driven opener can never fire. Verified
by pressing it: the prompt did not open. The keycode case is forced by SDL, not a
stylistic choice, and the comment at the site now says so.

- [x] S1. Reverted to the keycode opener. `CMDLINE_OPENER` and the character
      match both existed only to serve the suppressor, and are gone with it — the
      opener is now a plain keycode binding with no echo cleanup kept in sync
      against it, so the two sites that had to agree are down to one.
- [x] S2. A `:` typed into an open prompt is data, not another opener
      (`open C:/foo`), which the keycode opener gets for free: nothing inspects
      the character to decide, so there is no match to get wrong.
- [x] S3. The opener reads the modifier off `event.key.mod`, not
      `sdl.GetModState()`. The event carries the modifier held when the key went
      down; the global state is sampled when the event is handled, so a Shift
      released in between loses the opener — which is the reported "prompt never
      opens" symptom. (The other seven `GetModState()` call sites in this file
      have the same latent race for hotkeys; left alone as out of scope.)
- [x] Probe: `ui_probe_cmdline_opener_asserts` pushes real SDL events through
      `sdl.PushEvent` and drains them with the real `handle_sdl_events`, driving
      the actual two-event sequence (Shift+`;` KEY_DOWN, then the echo). Covers
      the prompt opening empty, the echo being dropped, the next real character
      landing, the NO-echo case (the reported bug), and a `:` inside an open
      prompt being data. Mutation-checked: reverting the suppressor to
      "drop the next event" fails it with the exact reported symptom
      (`first typed char gave "", want "o"`).
      Two things this cost, both commented at their sites: this path returns from
      main before `sdl.Init`, so it brings up `INIT_EVENTS` itself (no display
      needed), and writing a `#raw_union` variant does NOT set the tag — a
      synthetic event stays `FIRST` and the app's switch never matches unless the
      tag is set explicitly. The S3 fix is what made the probe able to drive a
      modifier at all.
- [x] S4. The other four `GetModState()` call sites in the shortcut switch
      (`K_Z` undo, `K_Y` redo, `K_SPACE` play, `K_R` rename) plus the
      `ti.active` text-field path now read `event.key.mod` like the opener,
      and the reasoning is stated once above the switch instead of per-site.
      This is the latent race S3 named and deferred. It is not a
      microsecond-window problem: the app's main thread stalls (decode, GPU
      work), input queues, and by the time a queued KEY_DOWN is handled the
      user has typically released or changed the modifier — so Ctrl+Z can fire
      as a bare `z`, and Ctrl+Space as plain Space (a real transport toggle).
- [x] S5. The two `GetModState()` calls that must NOT change are now
      documented at their sites so the next audit does not "fix" them:
      `MOUSE_WHEEL` + Alt has no event-side alternative (SDL's
      `MouseWheelEvent` carries no `mod` field at all, unlike
      `KeyboardEvent`), and `read_mouse_input` is a per-frame sample of what
      is held *now* for shift-click/alt-click, with no discrete event behind it.
- [x] ACCEPT: covered headlessly by the cmdline-opener probe (opens EMPTY, first
      character lands with and without a text echo, a data `:` survives) and by
      the action-table probe (F1/undo/redo resolution). Correcting an earlier
      entry here: this was previously ticked as a "manual pass", which no human
      ever performed — every check here is a synthetic SDL event, never a real
      keyboard. A human on hardware is still worth doing once, mainly because it
      is the only thing that exercises SDL's real text-input delivery timing.

## Active 9 — Input layer: key state, actions, focus/consume routing

**Why:** the app had no `KEY_UP` path at all, so "is this key down" was
unanswerable; every consumer re-derived press-vs-repeat from raw events; the
shortcut table was a keycode switch inline in the poll loop; and text input was
routed by a nested `ti.active` → `edit_state.field` → shortcuts if/else, which
is why the `:` opener needs a post-hoc echo suppressor at all.

**Scope decision (2026-09-26): build the input METHOD, not a text editor.**
More advanced text editing is expected eventually, so the routing has to
accommodate a future editor owning keys — but no editor, undo stack, or
multi-line buffer is built now. The seam is the deliverable; the editor is a
later work-stream that plugs into it without reshaping what is here.

- [x] I1. `input.odin`: key state as the single source of truth —
      `held` / `press_edge` / `repeat` / `release_edge` tables plus a `drain`
      counter. Repeat is derived from "was already down" rather than the
      event's own `repeat` flag, because that flag is absent on some platform
      paths and "already down" is the definition either way. Fixed global, not
      a per-frame allocation: a key held across frames is still held, so this
      belongs to the session bucket, not frame temp.
- [x] I2. `KEY_UP` is now handled, and `handle_sdl_events` is documented as
      the app's only SDL poll site — which is what makes `drain` a meaningful
      scope (one call empties the queue, so "same burst of input" is
      comparable).
- [x] I3. Hold-to-jog. `K_H`/`K_L` sat inside the `!repeat` guard, so holding
      them did nothing and shuttle needed a tap per step. A repeat-aware branch
      now runs the jog on auto-repeat, placed so it is only reached when no
      field owns the key — a jog can never fire while the user is typing.
- [x] I4. `action.odin`: `Action` enum + one fixed binding table, replacing the
      inline keycode switch. `.None` is the zero value so an unresolved key needs
      no dummy and no parallel bool. Table is ordered MOST SPECIFIC FIRST and
      resolution takes the first match, which is what preserves `Ctrl+Shift+Z`
      (redo) beating `Ctrl+Z` (undo) and `Ctrl+Space` beating bare `Space`.
      Continuous jog is deliberately NOT an action — it is a repeat-driven rate,
      and a second definition of "held" in the table would conflict with `kbd`.
      No remap UI, no persistence. Behaviour preserved exactly, including that a
      bare binding fires regardless of extra modifiers (`Ctrl+S` still splits a
      clip — surprising, but this pass reproduces what the app does, not what it
      should do).
      **The modifier match is not a bitwise subset test, and the probe caught
      why.** SDL's combined masks are `KMOD_SHIFT == LSHIFT|RSHIFT`, meaning
      "either", so `(got & KMOD_SHIFT) == KMOD_SHIFT` demands BOTH shift keys and
      never matches — which silently disables every modified binding while still
      compiling. `mods_have` now walks the four L/R pairs and requires at least
      one side, falling back to a plain subset test for unpaired flags
      (CapsLock/NumLock). Pinned by probe cases for left *and* right Shift/Ctrl.
- [x] I5. Focus/consume routing. `route_key_down` is now the single entry point
      for every KEY_DOWN, with the owner order stated once in a comment instead
      of being implied by if/else nesting depth: text field -> number field ->
      app. Each owner returns whether it CLAIMED the key and a claimed key stops
      travelling, so there is exactly one path to the app layer. Split into
      `field_claims_key` / `edit_field_claims_key` / `app_claims_key` plus
      `dispatch_action`; `handle_sdl_events` now just calls the router and no
      longer contains a 170-line nested branch.
      Two owner behaviours preserved deliberately, and both are one-line changes
      if anyone decides otherwise:
      - The text field claims EVERY key, not just the ones it acts on. The old
        branch had no exit, so with the prompt open `u` did nothing instead of
        toggling links.
      - The number field is the opposite: it takes Backspace/Enter/Esc and
        passes everything else down, so shortcuts work while typing a playhead.
      Pinned by probe (`key routing ok`), which asserts the CLAIM rather than
      firing real actions at the seeded session.
      Note, verified against the compiler rather than inferred: a bare `case:`
      is the runtime else of an Odin value switch. `#partial switch` is the
      enum-only variant that falls out on no match, and combines with a bare
      `case:` to act as its else. A full switch on an enum is still required to
      be exhaustive — a bare `case:` does NOT satisfy that, and the compiler
      answers "Unhandled switch case" and suggests `#partial`, so reaching for
      `case:` to silence it does not work. `when` is unrelated to all of this:
      it is a compile-time conditional where only the taken branch is
      typechecked, and its `default:` is compile-time dispatch rather than a
      runtime fallback. `edit_field_claims_key` needs a `case:` arm purely so the
      switch can report that it did not match — with no field open the router
      never calls it, so the arm is inert.
- [x] I6. Echo prevented at the source; the suppressor deleted. The echo was
      never a stray event to filter — the app caused it. `text_input_begin`
      called `sdl.StartTextInput` while the keypress that opened the field was
      still being handled, and SDL's own header says activating an IME "can
      prevent some key press events from being passed through" (`SDL_keyboard.h`,
      `SDL_StartTextInput`). The opening `:` is not a typing keypress, but
      enabling text input around it brought the IME up mid-handling, and the key
      came back out as a text event that landed in the field it had just opened.
      The suppressor was filtering a self-inflicted event, and everything it
      needed — a character match, a drain counter, a one-shot latch — existed
      only to guess which text events were the echo and which were real typing.
      The fix is ordering, not filtering. A field now *requests* text input
      (`ti.text_pending`), and `text_input_flush_pending` enables it once, after
      the event drain. SDL emits no TEXT_INPUT while text input is stopped (the
      fact the reverted text-driven opener established), so the opening keypress
      is consumed with text input off and produces no text event at all. The
      echo is ungenerable, which leaves nothing to correlate and nothing to
      swallow. IME is untouched — it is simply brought up between keystrokes
      rather than during one, which is also the only way to have it and still
      have the IME idle when no field is focused.
      `ti.text_on` records what SDL was actually told, separately from
      `ti.active`, which is only what the app wants. The two differ for a field's
      whole first frame, and a field that opens and closes inside a single drain
      never turns SDL text input on at all, so it must not later stop text input
      that was never started.
      Cost, recorded: the pending request is consumed even when there is no
      window to enable text input on, so a field opened before the window existed
      would never get text input. The window is created at startup before any
      field can open, so this is unreachable in the app; the probe runs in
      exactly that state, which is why it asserts the bookkeeping and not
      `SDL_TextInputActive`.
      Correction to the original I6 rationale, which was wrong on both counts. It
      claimed the drain scoping was "breaking `open C:/foo`" — it was not; the
      old suppressor cleared its flag on *any* text event, so the leading `o`
      consumed the stale flag before the path's colon arrived, and the case
      passed by coincidence. And the follow-up claim that a `:` typed first into
      an open prompt was "fixed" was describing a bug in a heuristic that no
      longer exists: with nothing armed, there is no flag for a keystroke to
      clear or trip over, and `:C:/x` lands whole.
- [x] ACCEPT: `:` opens empty; the first typed character lands; a `:` typed as
      data immediately after the opener lands whole (`:C:/x`), and a drive path
      arriving in a later drain (`oC:/x`) is unaffected; a field opened during a
      drain parks the text-input request instead of acting on it, and the request
      does not outlive the flush; jog moves on the tap AND on auto-repeat, and
      does not fire while a field is open; Ctrl+Z/Ctrl+Space resolve per binding
      table.
      The probe's echo case was DELETED rather than left passing. It asserted
      that a synthetic echo could be filtered, which was a statement about the
      suppressor and not about the app; keeping it would have left the probe
      asserting the existence of the thing this step deleted. What replaced it
      asserts the deferral directly — begin parks the request, flush consumes it.
      Remaining risk, stated plainly: this rests on SDL honouring the documented
      "no TEXT_INPUT while text input is stopped". A platform that echoed anyway
      would insert a single stray `:` into the otherwise-empty prompt, so the
      fault is visible rather than hidden — the prompt would start with `:` where
      it should be blank. That is the right way round: the old suppressor hid
      exactly this class of fault, and a bad platform now shows a cosmetic
      artifact instead of quietly eating a keystroke. Only real hardware can
      settle which platforms do which.
      Not covered by automated evidence: a human on real hardware with a real
      keyboard and a real IME, which is the only thing that exercises SDL's
      actual IME activation timing.

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
- **Zero-copy GPU->encoder interop (NOT planned; hardware encode itself IS
  shipped)** — Hardware encode is already the export default. `.GPU` opens the
  first encoder that actually works on the machine — `h264_nvenc`, `h264_vaapi`,
  `h264_qsv`, `h264_amf` on Linux, `h264_videotoolbox` on macOS, nvenc/qsv/amf
  on Windows — and falls back to libx264; the candidate list itself now lives in
  `hw_encode.odin` (shared with the proxy path);
  `enc_probe.odin` reports which one actually opened (`h264_vaapi` on this
  box). What is NOT implemented is the step after that: keeping the composited
  frame on the GPU so the pixel conversion and the surface upload never reach
  the encoder thread at all.
  Export is CPU-pipeline-bound; the encoder thread is the gate at 3.74 ms/f
  for 240x1080p60 (RGB->NV12 SIMD 1.87 + VAAPI surface upload 1.03 +
  h264_vaapi 0.84), everything else (producer 1.97, composite+audio 2.20) sits
  under it. Note which terms are actually on the table: the `h264_vaapi` 0.84
  is the hardware encoder ALREADY IN USE, so the remaining win is only the
  conversion and the upload, via Vulkan<->VAAPI dma-buf interop
  (VK_EXT_external_memory_dma_buf -> prime fd into the VAAPI surface).
  Risky/hard: FFmpeg's vaapi encode path
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
- **Preview proxies encode on hardware by default, software = fallback** —
  Same candidate list as export, now shared: `hw_encode.odin` owns
  `hw_enc_candidate_names` / `hw_enc_open` and both `render.odin` and
  `proxy_encode.odin` call it, so a hardware encoder is accepted only when a
  real `avcodec_open2` succeeds (a registered name without the device behind
  it is the common case on a machine with no hardware encoder). Proxy HW path
  scales to NV12 and uploads via `av_hwframe_get_buffer` +
  `av_hwframe_transfer_data` before the send; CPU keeps crf 26 / ultrafast /
  fastdecode. `VYPER_PROXY_ENCODER=cpu` forces the fallback so a probe on a
  machine that HAS hardware can still exercise it.
  Rate control is sized per encoder, not shared: `proxy_hw_bitrate` derives
  bits/pixel/frame (`PROXY_HW_BITS_PER_PIXEL`) because constant-quality has no
  single option name across nvenc/vaapi/qsv/amf. Measured 10s 1080p source →
  768x432 all-intra: VAAPI 957 KB vs libx264 1.48 MB, equal or better frame
  agreement — the hardware path is also the smaller artifact, so the default is
  a strict win. `PROXY_SUFFIX` deliberately does not encode the choice: keying
  the cache by encoder would make the fallback permanent and invalidate every
  existing proxy for output nobody watches.
  `proxy_probe.odin` now reports artifact size — it is the only place rate
  control is observable, so a retuned constant is visible instead of silent.

## Implemented — miniaudio audio backend (2026-09-26)

- Replaced SDL audio with vendored miniaudio (0.11.25). Device opens via
  `ma.context_init` (default backend enumeration, null last), negotiated
  at 48 kHz stereo S16; resampler uses `ma.resample_algorithm.linear` only
  when rate differs. Callback and ring are lock-free SPSC; device started
  once for lifetime with atomic transport gate.
- Moved audio device state to `audio_device.odin`. `audio.odin` contains no
  SDL audio calls. Producer/telemetry integration unchanged in shape.
- Producer→ring write loops on short grants (cursor wraps to 0 on commit),
  so a partial contiguous grant is retried inside the same push; the former
  producer-side carry buffer was removed entirely. Consumer callback loops
  across ring wrap on read (direct and resampled paths). These are the
  invariant fixes for the measured 1024-frame clamp per wrap.
- Added frame-domain accounting, underrun/callback diagnostics, and explicit
  clear/active semantics. Probe/autoplay exercised decode, mix, callback and
  queue depth remains stable at the target cushion.
- Time base moved off SDL: `clock.odin` owns one monotonic source
  (`CLOCK_MONOTONIC_RAW` via `core:time`) and native `time.sleep`, replacing
  42 `sdl.GetTicksNS`/`GetTicks`/`Delay` sites across 9 files. Had to be
  all-or-nothing: `gpu_draw.odin` subtracts the producer's `playback.dev_at_ns`
  stamp from its own reading for the A/V skew HUD, so a partial swap would have
  silently mixed two epochs and made that subtraction garbage. Also drops SDL's
  u32 tick wrap (~49 days) from UI notice deadlines. Side effect: SDL is no
  longer imported by any audio file.
- `./scripts/gate.sh check build probe smoke` pass; Valgrind: 0 definitely
  lost, 0 indirectly lost, no invalid access; error contexts unchanged from
  baseline (FFmpeg/Odin noise only). Branch `audio/miniaudio`, baseline
  `97f5267`, committed locally (no push).
