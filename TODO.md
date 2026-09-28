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

**Landed 2026-09-27 — in-tree CPU resampler replaces per-frame `sws` in the
keyed path.** `yuv.rgba_resample` (new, `vendor/yuv/resample.odin`) does 1:1
copy, box for minification, 2x2 bilinear for magnification, allocation-free per
frame, driven by an incremental 16.16 footprint walk. `render_eval_keyed_geom`
now calls it; the per-frame `sws.getContext`/`freeContext`/`scale` is gone from
that branch. Measured (`./scripts/gate.sh bench`, `swsbench/bench.odin`):

| case | swscale | kernel | speedup |
| --- | --- | --- | --- |
| animated ~0.9 (near 1:1) | 15.5 ms | 1.47 ms | 10.6x |
| 0.5x downscale | 7.16 ms | 2.51 ms | 2.9x |
| **3x downscale (the reported 1->3)** | **68.3 ms** | **20.6 ms** | **3.2x** |
| 1:1 | 0.22 ms | exact copy | - |

End-to-end on a 600-frame 1080p keyed export with a real resample every frame:
14.15 s -> 8.50 s (1.66x), PSNR 37.5 dB between the two encodes. Against the
119.3 ms/frame baseline recorded above, the kernel is 5.8x on the reported
shape.

Correctness is gated, not assumed: `swsbench`'s `kf_vs_swscale` compares the
kernel to swscale per geometry and currently reads mean_abs `0.11` (0.5x),
`1.16` (2x upscale), `0.06` (3x downscale), `0.00` (1:1, exact). Three real
bugs were caught this way and would all have shipped silently on timing alone:
bilinear used as a minification filter (point-samples every other pixel under
2:1), a packed-u32 accumulator carrying alpha overflow into blue, and a
reciprocal scaled by 65536 with no compensating shift.

**Still open — the GPU path, which is the real default.** 20.6 ms/frame on the
3x shape is 18.7 Mpx of scalar taps; on the GPU the same box filter is a few
texture fetches, so the ceiling here is the CPU's tap count, not its
throughput. See the note appended to S2.

**Implementation order (each step lands with probe + vet before next):**
- [x] S0. In-tree CPU resampler for the keyed path (landed above). This is the
      fallback the GPU path must match or beat, and the correctness gate every
      later step is measured against.
- [ ] S1. Add an opt-in headless export benchmark fixture for scale `1 -> 2`,
      `1 -> 3`, constant scale, transform-only, crop-only, reversed scale, and
      off-canvas motion. Record wall time, producer time, keyed `sws`, stage
      dimensions, output frame count, and a reference-frame hash/PSNR.
- [x] S1b. GPU resample as the DEFAULT, CPU kernel as the fallback. Decode the
      keyed stage once into a texture, then resolve the animated box as a
      filtered textured quad (a hardware bilinear sample per output pixel) with
      no per-frame CPU resample at all — the Resolve pattern. This is the
      largest remaining win on the 3x shape and the reason S0 is a fallback
      rather than the destination. Needs: a keyed-path GPU compositor, a
      readback or GPU-side encode hand-off (the export currently hands a CPU
      `canvas` to `rend_enc_video_frame`), and a capability check with the CPU
      kernel as the fallback when no usable context exists. Kept as a separate
      step because it is a compositor change, not a resampler change.

      **Status: stage 1 landed as a probe (`gpu_resample_probe.odin`,
      `scripts/gate.sh gpu_probe`), measured 2026-09-27.** Headless offscreen GPU
      resample works with no window: `SDL_Init(SDL_INIT_VIDEO)` is still
      required (`CreateGPUDevice` fails with "Video subsystem not
      initialized" otherwise), and `CreateGPUDevice`'s third argument is the
      `SDL_HINT_GPU_DRIVER` *value*, not a device name — a free-form string there
      is rejected as an unknown driver. `nil` auto-selects; `"vulkan"` is the
      explicit retry.

      Measured against the S0 kernel, 1600x900/800x450 source pair:

      | geometry | GPU | CPU kernel | speedup | mean/peak |
      |---|---|---|---|---|
      | 1600x900 -> 1600x900 | 1.31 ms | 0.35 ms | 0.27x | 0.00 / 0 |
      | 1600x900 -> 800x450 | 0.99 ms | 10.8 ms | 10.9x | 0.20 / 1 |
      | 800x450 -> 1600x900 | 0.78 ms | 49.5 ms | 63.5x | 1.16 / 7 |
      | 5760x3240 -> 1920x1080 | 8.57 ms | 92.7 ms | 10.8x | 0.05 / 1 |

      Two findings that change the design:

      1. **A half-texel inset is wrong here.** Mapping destination pixel center
         `p` to `p/src_w` is exact for 1:1, so `src_rect` must be the exact
         source rect `(0,0,1,1)`. Insetting the endpoints shifts the image half
         a texel; the 1:1 exactness gate is what caught it, which is why that
         gate is not optional.
      2. **A single point-sampled bilinear fetch ALIASES under minification.**
         On a high-frequency fixture (1px checkerboard + 1px rules + hash) the
         3x downscale reads mean 39.9 / peak 202 against the box reference,
         because the box averages a 3x3 footprint to uniform grey while one
         bilinear tap keeps checkerboard contrast. A band-limited fixture hides
         this entirely (the same row reads mean 0.05), so the probe runs BOTH:
         `SMOOTH` catches geometry errors, `HIFREQ` catches filtering errors.

      Consequence: hardware filtering alone is **not** an acceptable export
      default for minification. S1b needs prefiltered downsampling (a footprint
      kernel, or mip levels) rather than one filtered quad, which also has the
      useful property of making the GPU and the CPU fallback produce the same
      image — otherwise "fallback" is a silent quality change. The probe's
      `OPEN_ALIASING` row is deliberately reported-not-asserted until that
      lands, then flips to `GATED` with the 8/32 budget it already carries. The
      `NYQUIST` rows stay ungated permanently: at 1px checkerboard two correct
      resamplers differ by phase, and asserting it would demand one filter's
      convention rather than quality.

      **RESOLVED 2026-09-27 -- aliasing fixed and gated; the default can flip.**
      The blocker was never the hardware. Recapping, because two wrong turns got
      here and the notes should not repeat them:

      - The box has an AMD GPU: `amdgpu` kernel driver, PCI `1002:15BF`
        (Navi 33 / Radeon 760M), with `/dev/dri/card0` and
        `/dev/dri/renderD128`. An earlier revision of this note claimed no GPU
        at all. That came from `lspci` not being installed -- its empty output
        was absence of evidence -- plus a truncated `ls` that hid the render
        node. Never infer hardware from a tool that is not installed.
      - The loader really was handing SDL3 `llvmpipe`, but the cause was a
        **stale binary** carrying a different Vulkan loader and ICD search path,
        not a missing ICD and not `RADV_PERFTEST` (the second wrong guess;
        `RADV_PERFTEST` is unset on this box and the 760M is used regardless).
        The permanent fix is that the probe now prints
        `SDL_PROP_GPU_DEVICE_NAME_STRING` on every run, because the driver
        string cannot distinguish hardware from software -- llvmpipe reports
        backend `vulkan` exactly like a real adapter, which is what made a
        green run readable as hardware. A software rasterizer is now a loud
        warning, not a silent substitution.

      **The aliasing fix is a fragment-shader box filter** (`shaders/blit_box.frag`),
      one `texelFetch` per covered source texel -- the same footprint the CPU
      kernel walks. Sampler-side reconstruction was measured and is dead on this
      driver, so it is not relied on:

      - The mip chain generates successfully (11 levels at 1600x900, no SDL
        error) and a shader hardcoding `textureLod(3.0)` still returns level-0
        data, bit for bit.
      - A sampler `mip_lod_bias` of 4.0 and 8.0 changed nothing, including at
        1:1 where a live bias must visibly blur.
      - 16x anisotropy was bit-identical to 1x. Aniso needs mips, so both being
        inert is the same fact: this driver clamps every lookup to level 0.
      - `VYPER_GPU_PIN_LOD` is kept as the standing test for whether a future
        driver does honour a mip level.

      Two shader details were load-bearing, and both were found by measuring
      rather than reasoning:

      - Taps must be `texelFetch`, not `texture`. Filtering taps interpolate
        before averaging, double-blurring on top of the box: the 2:1 case
        measured mean 5.07 / peak 36 against the CPU reference, worse than no
        averaging at all.
      - The footprint must start at the first texel whose *centre* is inside it,
        `floor(center - rho/2 + 0.5)`, not `floor(center - rho/2)`. The bare
        floor lands a whole texel low, which is the off-by-one the failure
        samples showed at the last pixel, `(1599,0899) gpu=102,084,063` against
        `cpu=103,085,064`.

      Results on the 760M, box path, against the CPU kernel as reference:

      | case | mean | peak | budget | was (bilinear) |
      |---|---|---|---|---|
      | 1:1 SMOOTH | 0.00 | 0 | exact | 0.00 |
      | 1:1 HIFREQ | 0.00 | 0 | exact | 0.00 |
      | 0.5x SMOOTH | 0.20 | 1 | ok | 0.20 |
      | 0.5x HIFREQ | 0.11 | 1 | ok | 0.11 |
      | 2x SMOOTH | 1.16 | 7 | ok | 1.16 |
      | 3x SMOOTH | 0.02 | 1 | ok | 0.05 |
      | **3x HIFREQ** | **0.02** | **1** | **8/32** | **39.94 / 202** |

      The 3x high-frequency row is the one that mattered and it went from a
      severe aliasing regression to agreement with the CPU kernel. That row is
      now `GATED` at 8/32 rather than reported, so it is a regression gate. The
      `NYQUIST` magnification row stays ungated permanently: at 1px checkerboard
      two correct resamplers differ by phase, and asserting it would demand one
      filter's convention rather than quality.

      Speed on the 760M, end to end including upload and synchronous readback:
      0.5x downscale ~9-10x, 2x upscale ~45-50x, 3x downscale ~7.5-8x, all
      against the scalar CPU kernel. 1:1 is slower on the GPU (0.9-1.7 ms vs
      0.2-0.3 ms) because the probe pays upload and `WaitForGPUIdle` per
      iteration, which is exactly the cost the direct NV12 hand-off would remove.

      Shader compilation is now a build step (`scripts/gate.sh shaders`, run by
      `build`) and the blit shaders are in the flake's `buildPhase`. The SPVs
      are `#load`-ed at compile time, so rebuilding without recompiling keeps
      the old shader -- which happened here and produced a confidently wrong
      measurement.

      **Stage 2 landed 2026-09-27 -- the GPU resampler is now the default on the
      keyed path, with the CPU kernel as the automatic fallback**
      (`render_gpu.odin`). `render_eval_keyed_geom` calls
      `gpu_resample_into` for `scale_keyed` clips and falls through to
      `yuvconv.rgba_resample` on any failure, so a driverless or capability-less
      machine still exports correctly. `VYPER_KEYED_GPU=0` pins the kernel for a
      controlled A/B.

      Only the *resample* moved to the GPU. The result still lands in
      `kres_scratch` and the existing `render_blit_region` copies it to canvas,
      so z-order, keyed/static interleaving, and off-canvas clipping are
      untouched and provably unchanged. The direct canvas composite and the
      NV12 hand-off are the next step, not something this stage claims.

      End-to-end on the synthetic 90-frame 1920x1080 keyed export at 0.5x
      (`./scripts/gate.sh keyed_export`):

      | | composite | videoenc |
      |---|---|---|
      | GPU (default) | 3.33 ms/f | 5.99 ms/f |
      | CPU kernel (`VYPER_KEYED_GPU=0`) | 17.45 ms/f | 6.65 ms/f |

      ~5.2x on the composite stage, which was 69-73% of the frame; the encoder
      is unchanged as expected. The same shape as the isolated probe's 8-10x
      because this measurement also pays the upload and the readback the
      hand-off is meant to remove. Re-run with `./scripts/gate.sh keyed_export`;
      the numbers move a few percent run to run.

      **Parity, with the control that makes it readable.** The gate asserts two
      things at two scales, and the 1:1 row is the load-bearing one:

      - 1.0x: **bit-exact** (PSNR `inf`) against the kernel through the real
        compositor and encoder. That case is a copy, so any difference is a real
        seam defect -- a half-texel inset or a wrong viewport shows here -- not
        a rounding question.
      - 0.5x: 58.7 dB, floor 50. Minification legitimately differs in the last
        LSB because the shader derives its footprint start in float while the
        kernel walks integers. Equivalent, not identical, and the target says so
        instead of implying the two are the same code.

      The control is what licenses reading that 58.7 dB as resample difference:
      x264 is deterministic, so two kernel-pinned runs of the same input are
      bit-identical (`inf`), which means the encoder contributes exactly zero.
      Without that run the gate would be measuring the codec.

      Two things this stage got wrong before it was gated, both worth recording
      because both would have shipped silently:

      - **The stage upload cache never hit and was a stale-frame bug waiting to
        happen.** It skipped the upload when the source address and size matched
        the previous call. Measured: 90 uploads, 0 hits over 90 frames -- the
        compositor's blit slots are a two-slot ring (`frame_idx & 1`) that is
        re-pointed per frame, so the key never repeated. It bought nothing and
        was one addressing change away from serving a stale frame, so it is
        deleted rather than kept as a comment; the *texture* is still reused so
        the hot path never re-creates a driver object.
      - **A green PSNR number hid a stutter for a while.** `testsrc2` is mostly
        static, so a frozen upload still scores well against a correct render
        on a whole-video average. The check that actually settles it is
        per-frame: `gpu[0]` vs `gpu[2]` reads the same 27.18 dB as the
        `cpu[0]` vs `cpu[2]` control, so the GPU output tracks frame for frame.

      The compositor is a process-lifetime singleton held as a *value*
      (`gpu_resample_singleton`), not a heap pointer: one instance, created
      once, nothing to free. A failed creation latches `gpu_resample_disabled`
      so a driverless environment does not retry device creation on every keyed
      clip of every frame. It initializes `SDL_INIT_VIDEO` itself when needed
      and only calls `QuitSubSystem` if it was the one that brought video up --
      a worker tearing down the subsystem would take the UI's window with it.
      Source and destination byte counts are asserted at the boundary, because
      both are raw pointers into a `w*h*4` copy and neither can be bounds
      checked from the pointer alone.

      Remaining for S1b: GPU composite straight to canvas (removing the
      `kres_scratch` readback), GPU RGBA->NV12, and the direct NV12 hand-off to
      `hw_frames_ctx`.
- [ ] S1c. GPU composite straight to canvas, then GPU RGBA->NV12 handed
      directly to `hw_frames_ctx`. S1b still round-trips each keyed resample
      through `kres_scratch` and a CPU `render_blit_region` because keyed and
      static clips interleave in z-order, so compositing on the GPU needs
      either a reordering that preserves overlap semantics or one composite pass
      per clip into a GPU canvas. Dropping the readback is what removes the
      upload/download cost that currently caps the win at ~5x rather than the
      probe's 8-10x.
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

**Out of scope:** preview keyframe sampling and encoder changes. The GPU
compositor originally listed here is no longer out of scope -- S1b landed it
because the remaining CPU geometry work (S2-S4) is bounded by a tap count the
GPU does not have.

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

## Active 10 — Preview/export parity cleanup (shared geometry, filter, layering)

**Status:** started 2026-09-27. Goal is to remove the duplicated preview/export
machinery and fix the bugs that duplication already caused, BEFORE attempting to
unify the two pipelines. Unification itself is deliberately not started: it
needs a zero-copy interop spike (Active 1 / S1c) and is a project of its own.

All three parity bugs are fixed (A1/A2 for the filter, B/B2 for geometry, C for
layering, D for subtitles) and `all` is green. Still open in this section: the
preview's UV arithmetic is NOT merged with the export's, on purpose — see the
note under B2 — and the remaining duplicated machinery is decode/stage sizing
and preview/export text rasterization.

Three SHIPPED bugs were found while mapping the duplication, all of them
consequences of two systems maintaining the same fact independently:

1. **Preview minification aliases.** `preview.frag` is a single `texture()`
   tap and the preview sampler is `LINEAR` with `max_lod = 1`, so a 1080p
   source shown in a ~600px widget is minified with one bilinear tap and no
   mip chain. The export side already got this right via
   `shaders/blit_box.frag`; preview never adopted it.
2. **Text vs video layering diverges.** Preview walks the track order once and
   interleaves `.Video` and `.Text` by that walk position. Export ran three
   SEPARATE passes: videos in reverse `render_job.videos` order, then all
   texts, then all subs. A text clip on a track below a video therefore
   previews underneath but exports on top. The comment at the text pass
   claimed it "match[es] the preview layering" — it did not.
3. **Subtitles vs everything diverges.** Subtitle generator clips arrive in
   preview as `kind == .Text` + `generator == .Subtitles`, so they take a
   `layer` from the same walk and interleave. Export pinned all subs above
   everything, with a comment claiming that matches the preview. (Fixed by
   Step D; there was no `subs_pinned` flag in the tree despite an earlier
   note here saying there was.)

Decision (user, 2026-09-27): **track order is authoritative for text in both;
subtitles stay pinned on top in both.** Text below a video must preview and
export identically (WYSIWYG). Burned-in subtitles stay above everything because
a subtitle hidden behind a video is unreadable, so preview must pin them too
rather than interleave.

**Step A1 — DONE: one vertex stage, one uniform type, one shader load.**
- `shaders/text.vert` and `shaders/blit.vert` were byte-identical in math
  (same `corners[6]`, same `bounds.xy + corner*bounds.zw`, same NDC + Y-flip,
  same `mix(uv.xy, uv.zw, corner)`) and differed only in field names. Merged
  into `shaders/quad.vert`; both old files deleted. Kept at the default
  target-env so the text/preview paths still run on a Vulkan 1.0 device.
- `TextVertexUniforms` and `Blit_Uniform` were two types for the same block
  with INCOMPATIBLE field order (text: bounds, viewport, pad, uv; blit:
  dst_rect, src_rect, viewport). Now one `Quad_Uniforms` matching
  `shaders/quad.vert`, with the byte-layout contract documented on the type.
  The `_padding` is load-bearing: it puts `uv` at offset 32, where std140
  puts the vec4 following a vec2.
- `render_gpu.odin` referenced `blit_vertex_spirv`, which was `#load`-ed in
  `gpu_resample_probe.odin`. Production code depended on a symbol declared in a
  probe file; deleting the probe would have broken the build. The load now
  lives with the other `#load`s in `gpu_renderer.odin` and all three
  consumers share it.
- The probe built its uniform as an INLINE ANONYMOUS STRUCT in the old blit
  order, which is how the fields land in the wrong place when the vertex
  stage changes — it failed the probe until it used the shared type. That is
  the exact hazard the shared type exists to prevent, and the most likely
  place for the next silent break.

**Step A2 — DONE: preview adopts `blit_box.frag`, fixing bug 1.** Bug 1 was the
reason the export path had to be dragged into a preview conversation: two
filters for one job, and the one preview used was the wrong one. `preview.frag`
(a single `texture()` tap) is deleted; the preview pipeline binds the same
`blit_box.frag` + `quad.vert` + `Quad_Uniforms` triple the export compositor
uses, so the two can no longer disagree about filtering.

Deployability: `blit_box.frag` was built `--target-env vulkan1.1`. Binding it
into the preview pipeline would have made the WHOLE app fail to start on a
Vulkan 1.0 device, since a failed `create_gpu_renderer` takes the window down
with it. The shader uses nothing from 1.1 — recompiling at the default target
env emits an identical instruction stream with only the SPIR-V version word
changed (1.3 -> 1.0) — so every stage is now plain Vulkan 1.0 and the per-file
env special case is gone from both build lists.

**Cost, measured on this box (Radeon 760M) rather than eyeballed.** The box
filter's tap count multiplies OUTPUT pixels, not source pixels, so the preview
can afford it where the export cannot be casual about it. Two rows were added to
the existing resample probe, which already takes arbitrary src/dst sizes, rather
than inventing a new timing path:
- `1920x1080 -> 600x340` (3.2x reduction, the common "1080p in a ~600px
  widget" case): **1.69 ms**.
- `5760x3240 -> 640x360` (9x, past `MAX_TAPS`, the worst case from zooming a
  5K source out): **11.0 ms**. The 6x cost over the near-identical output size
  of the row above is cache pressure from sampling a 75 MB source texture, not
  extra taps — the tap count is capped at 4x4 either way.

`MAX_TAPS = 4` already bounds this, so cost does not grow without limit as the
user zooms out; the worst case is bounded, not merely smaller than export's.

**A filter property the preview regime exposed.** The shader takes `ceil(rho)`
taps per axis, while the CPU kernel walks the exact covered interval
(`sx0 = floor(x_pos)`, `sx1 = floor(x_end)`, 16.16 fixed point). The two agree
at INTEGER ratios, which is all the export ever produces because stages are
sized as integer multiples — its rows measure mean 0.20 (2:1) and 0.02 (3:1).
Preview ratios are arbitrary (1920/600 = 3.2), so the tap count overshoots the
footprint by up to one texel per axis and the kernels drift: measured mean 2.22
/ peak 11, about 0.9% of range on a smooth gradient. Imperceptible on an
interactive surface, and the row is still GATED so a geometry or sampler
regression cannot hide inside the budget. Making the shader track the CPU
interval exactly would fix it properly, but it changes a filter the export path
is BIT-EXACT on at 1:1 — if that anchor moves, the exactness gate stops meaning
anything — so it wants its own re-validation, not a rider on a preview change.

**Not yet done for A2:** the preview's own PIXELS have not been captured before
and after. The filter is validated in isolation by the probe, the pipeline is
confirmed created (no creation-failure output, `smoke` green), and the same
shader/uniform pair is proven on the export path — but `scripts/gate.sh probe`
submits no GPU work at all, so it cannot show the moiré is gone. That needs a
probe that renders the preview and reads it back.

**Step B — DONE: geometry dedup into `project_geom.odin`.** `clip_full_box_dims`
(preview_transform.odin) and `render_full_box_dims` (render.odin) had identical
bodies, and the render copy carried a comment admitting it was "mirrored here
for snapshot structs". The `center - size/2 + crop*size` formula was likewise
written twice, once in float screen pixels and once rounded to ints.

New `project_geom.odin` owns two PURE primitives: `full_box_dims` and
`cropped_box_edges`. The preview's `clip_full_box_dims` survives as a 6-line
wrapper and that is deliberate, not leftover indirection: the export compositor
runs on a worker thread against a `Render_Job` snapshot and must not read the
`project` globals at all, so it needs the canvas size passed in, while the
preview legitimately reads live state. One implementation, two honest access
patterns.

`cropped_box_edges` returns EDGES rather than origin+extent on purpose. The
export rounds the edges to whole output pixels, so a width formed any other way
can differ from `r - l` by a pixel. The preview now derives its extent from the
same edges instead of recomputing `sw*(1-crop_l-crop_r)`, which is the ULP-level
disagreement that let the two drift.

Verified: `keyed_export` still reports `1.0x PSNR = inf` and
`0.5x PSNR = 58.707992`, i.e. export output is bit-identical.

**Step B2 — DONE: one crop→source-pixel-rect, closing the gate's blind spot.**
`cropped_box_edges` (above) settles where a crop lands in DESTINATION space, but
the export has a second, separate question it was answering twice: which SOURCE
pixels does the crop select. Two copies, with different arithmetic:

- `render.odin` (GPU staging): `clamp(c.int(cl * f32(stage_w) + 0.5), 0, ...)` in
  f32, over the staged texture.
- `render.odin` (CPU sws): `int(f64(v.crop_l) * f64(v.fw) + 0.5)` in f64, over
  the full-box blit, with the same shape of clamp spelled out again.

That second copy is not a style problem, it is a hole in the gate. `keyed_export`
scores the GPU path against the CPU path as its reference, so the two agreeing on
"this crop means these pixels" is the PREMISE of the PSNR number — and a rounding
or clamp policy that drifted between them would quietly lower the score rather
than fail, which is the one failure mode a reference-comparison gate structurally
cannot catch. `crop_src_rect` in `project_geom.odin` is now the single answer, and
both paths call it.

The shared function is f32, matching the GPU path, because that is the one under
the bit-exact gate (`1.0x PSNR = inf`) and therefore the strictest available
opinion on the correct rounding; the CPU path adopted f32. Proven immaterial
rather than assumed: rendered the whole clip with `VYPER_CROP="0.1,0.2,0.05,0.15"`
before and after the refactor and compared — `average:inf`, bit-identical. Note
that `keyed_export` itself never sets `VYPER_CROP`, so its green result does NOT
cover the crop path; the before/after render is the evidence, not the gate.

**Orphan probe found while doing B.** `transform_probe.odin` is a 23-case
regression check for the preview handle/snap geometry, and it is the only thing
that exercises `clip_full_box_dims` and the crop/edge math — the exact code B
touched. It was reachable only by setting `VYPER_TRANSFORM_PROBE` by hand and
had no target in `gate.sh`, so it had not been running: a regression in the
geometry B refactors would have been invisible. Added `target_transform_probe`
and put it in the `all` list. It passes.

**Step B3 — DONE: the last hand-inlined crop edges, and the extent policy.**
Two more duplications, both found by asking "who else derives this number"
rather than by reading for style:

- `render_display_rect` (render.odin:928) re-implemented
  `cropped_box_edges` LINE FOR LINE — same `transform_x - cw/2 + crop_l*cw`,
  same four terms — directly below its own call to the shared `full_box_dims`.
  So Step B half-migrated that function: the box dims came from the shared
  helper and the crop edges did not, leaving the ONE place in the export still
  deriving crop edges on its own while the preview read the shared version the
  whole time. `render_kf_geom_rect` had been migrated; the static path was the
  odd one out. That is the drift B existed to stop, still present after B.
- The "float extent -> pixel count" policy (`max(1, c.int(span + 0.5))`, round
  half up, never zero) appeared 10 times across the keyed and static paths. It
  is now `px_extent` in `project_geom.odin`. The floor is the load-bearing half
  and the reason it is named: every caller sizes a blit rect or a GPU texture,
  where zero is not a small image but an invalid one. Origins deliberately do
  NOT route through it — those stay `c.int(math.round(v))` with no floor,
  because a clip can legitimately hang off the canvas at a negative coordinate,
  and flooring an origin to 1 would teleport every off-canvas clip to the
  top-left corner.

**`dec_crop_px` (decode.odin:1056) was left alone, deliberately.** It looks like
a fourth copy of crop->pixel-rect, and it is the same ROUNDING AND CLAMPING
policy, but it is a different function: it takes an already-computed normalized
sub-rect (`crop_fx0/fy0/fw/fh`) rather than four insets, and it has a
"zero fractions means no crop" contract that returns a `0,0,0,0` sentinel the
export's `crop_src_rect` has no notion of. It also serves a different consumer:
that rect crops the DECODER's own sws input, while `crop_src_rect` crops an
already-decoded full-box blit at composite time. Different input shape,
different contract, different job — merging them would be the "apparent
conceptual similarity" AGENTS.md 2 warns about, and would have to invent a
sentinel the export side has no use for.

**Decode/stage sizing between preview and export turned out to need no work.**
`open_clip_decoder_ex` has exactly two callers: the preview (decode.odin:380,
fixed `PREVIEW_W x PREVIEW_H`) and the export (per-clip stage size). One
implementation, two destination sizes passed in as a parameter — which is what
"shared" is supposed to look like. There was no second sizing implementation to
remove; the duplication was export-INTERNAL, which is what B3 fixed.

**Step C — DONE: one ordered visual list for export, fixing bug 2.** Video and
text were snapshotted into two parallel arrays and composited in two separate
passes -- "all video, then all text" -- so export drew every text clip above
every video regardless of track, while the preview interleaved them by track
position: a text clip on a lower track previewed UNDER the video and exported
OVER it. `Render_Visual` is now a union of BORROWING pointers
(`^Render_Video_Src` / `Render_Text_Src`) that records composite order, built by
the same track walk that fills the two arrays, and the compositor walks it once
back-to-front with a `#partial switch`. Subtitles stay in their own pinned pass.

Two things this got wrong first, both worth recording:
- The union originally held COPIES. The decoder opens each source and fills its
  blit slots AFTER the walk, so a copy would composite an empty slot forever --
  a black frame that looks like a decode failure, not an ordering bug.
- Because the union borrows into `cls`/`txts`, both are `reserve`d before the
  walk: a mid-walk realloc would dangle every pointer already recorded.

**z-order test (`./scripts/gate.sh zorder`, in `all`).** Three runs of one
source differing only in where a TEXT clip sits: `base` (video only), `below`
(text on a track under the video), `above` (text over it). `below` must be
PIXEL-IDENTICAL to base -- text behind an opaque video leaves no trace -- and
`above` must differ. The two arms assert mutually exclusive outcomes, so a
compositor that ignored track order (the old behavior, text on top either way)
fails the `below` arm. No pixel color is guessed, only equality against the
baseline. Result: `below=inf`, `above=27.377424`.

**Step C also exposed a crash and a silent-corruption hole, both fixed:**
- Exporting ANY text clip headlessly segfaulted. `render_test_run` is dispatched
  at main.odin:1337, before `load_font_data()` at main.odin:1463, so
  `font_state.data` was nil and `stbtt_InitFont` read out of bounds -- a crash
  naming neither stb nor fonts. `text_metrics_px` and two sibling raster paths
  each carried their own copy of the lazy init, so the fix is one
  `ensure_text_font` that all three call, asserting the data is loaded at the
  cause. The interactive app was never affected, which is why it survived.
- `sync_track_order` asserted only that `track_order` had the right LENGTH, not
  that it was a permutation -- weaker than the invariant its own comment claims.
  Injecting a row into a not-yet-synced order produced `[1, 1]`, a duplicate that
  silently omitted the video track, so the export rendered a black frame while
  reporting success. It now asserts the permutation (in range, and each value
  exactly once), counted in place: sync_track_order runs on rendering and
  mutation paths, and an assert must not be the thing that allocates. An earlier
  draft used a scratch slice and leaked 4,158 bytes in 66 blocks, which the
  `valgrind` target caught immediately.

**Step D — preview pins subtitle slots, fixing bug 3.** Done.
Subtitle-generator slots took a `layer` from the same track walk as everything
else, so a subtitle clip on a low track previewed BEHIND the video while export
pinned it on top — the preview and the export disagreed about the same frame, and
a burned-in subtitle a video covers is unreadable either way. There was no
`subs_pinned` flag anywhere in the tree; the earlier note in this file claiming
one existed was wrong, and the whole mechanism is new.

`Preview_Slot` now carries `is_subtitle`, assigned on every claimed frame
next to `layer` so a slot reassigned from a subtitle clip to a video cannot keep
a stale flag. It is a flag and not a `layer` value on purpose: `layer` is also
the flash overlay's depth (`flash_rec.odin`), where it must keep meaning "where
this clip sits in the stack". The pinned depth is derived at the single place
that orders the composite — `preview_draw_key` returns the reserved key 0 for a
subtitle slot and `layer` otherwise, and the draw loop walks the list backwards
so the LOWEST key paints LAST. Key 0 sits below every track-assigned layer
(which start at 1), which is what makes "pinned above everything" expressible
without disturbing the track order of the rest of the stack.

The collect-and-sort moved out of `draw_preview` into `preview_build_draw_order`
so the rule is testable with no GPU pass and no live decoder — it is pure data
over `preview_slots`. `ui_probe_preview_order_asserts` covers six cases:
track order still decides between ordinary clips (both directions), a subtitle
on the BOTTOM track beats a video on the TOP track, pinning does not depend on
slot index (the case a stable-slot reassignment produces), two pinned subtitles
keep their relative track order among themselves, and an invisible pinned slot
stays out of the list. Verified as a real regression test: reverting only the
`is_subtitle` branch in `preview_draw_key` fails 3 of the 6, and the 3 that still
pass are the ones that must keep passing (ordinary track order) — the assertions
are not tautological. Export was already correct by construction (subs are a
separate pass after the single ordered visual walk), so this was preview-only.

**Gate hardening (done with A1).** `target_gpu_probe`, `target_probe`,
`target_smoke`, `target_valgrind` and `keyed_export` all ran `./vyper` WITHOUT
building it, checking only that it existed. Editing a source and re-running one
measured the PREVIOUS binary and reported it as the new one — the stale-SPIR-V
hazard the file already warns about, in its worse form. This actually caused a
misdiagnosis here: a real failure was chased as pre-existing and then as a
clean pass, when both runs were the same stale executable. All five now call
`require_fresh_binary`, which fails loudly (rather than silently rebuilding)
when any `.odin` or `shaders/*.spv` is newer than `./vyper`. Separately,
`target_shaders` listed only the blit trio, so editing `preview.frag` and
running a target measured the old SPIR-V; it now compiles every stage and
fails if a shader on disk is not in the list.

**Evidence for A1 (behavior-preserving):** with a real rebuild, `gpu_probe`
reproduces the baseline error metrics row-for-row (1:1 `mean=00.00`; 0.5x
`00.20`/`00.11`; upscale `01.16`; 5K `00.02`) and `keyed_export` reproduces
`1.0x PSNR = inf` and `0.5x PSNR = 58.707992` exactly.

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
- **Incremental export via a chunk cache (NOT planned now — design note so the
  idea is not re-derived)** — render the export as a sequence of ~1 second
  chunks (N frames at the project framerate) instead of one pass. Each chunk is
  encoded to its own file in a cache folder. On a later export, a chunk whose
  inputs are unchanged and whose file is already present is reused verbatim, and
  only the changed chunks are re-rendered. The chunk files are then concatenated
  into the final deliverable. The payoff is proportional to how often exports are
  re-run after small edits: changing one clip re-renders the chunks its visible
  span overlaps rather than the whole timeline.

  This is a design note, not a commitment. The hard parts are not the cache --
  they are the parts that decide whether the output is *correct*:

  1. **The cache key has to mean "nothing that affects these frames changed",
     and that is a much stronger claim than "the project file is unchanged."**
     At minimum the key covers: source identity (path + size + mtime, or a
     content digest of the bytes the chunk actually reads), the timeline state
     of every clip/effect/marker/text overlapping the chunk's time range, the
     global render settings (size, framerate, pix_fmt, codec, rate control), and
     **a renderer version**. That last one is the trap: without it, a change to
     the compositor silently reuses chunks rendered by the old code and the
     export is a mix of two renderers. Cheap-but-wrong is worse than no cache.
  2. **Invalidation is per chunk, so the question "which timeline items affect
     this chunk" has to be answered by evaluating the timeline over that range,
     not by diffing the project file.** A global change (resolution, codec)
     invalidates everything; a local edit invalidates only overlapping chunks.
     Anything with a tail longer than its own span (crossfades, envelopes,
     transition handles) widens the invalidation window, and that has to be
     derived, not assumed.
  3. **Concatenation must be a stream copy, which constrains the encoder.**
     All chunks need identical codec parameters (SPS/PPS, profile, level,
     timebase, pix_fmt) and each must start on a keyframe with a closed GOP, so
     every chunk is independently decodable. That means forcing a keyframe at
     each chunk boundary. `ffmpeg -f concat -c copy` then works without
     re-encoding, and frame counts must sum exactly -- no dropped or duplicated
     frame at a seam.
  4. **Per-chunk encoding is not the same encode.** Rate control looks ahead
     and allocates bits using future frames; a single pass over N frames is not
     the concatenation of chunk-wise encodes. Each chunk restarts its rate
     control, so the first frames of every second get more bits and quality
     pulses once per chunk. Fixed-QP/CRF largely avoids this; ABR does not.
     Decide explicitly whether "the export is always rendered chunk-wise" is
     acceptable, because otherwise the cached result and a fresh single-pass
     export are different encodes of the same timeline.
  5. **Audio is worse than video here.** Per-chunk audio encoding introduces
     encoder priming/padding (AAC delay) at every boundary, which shows up as
     clicks or drifting A/V sync. Most likely the mix has to be rendered once
     over the full range and muxed at the end, so only the video chunks are
     cached -- worth deciding before building, since it changes the shape.
  6. **A truncated chunk must never look valid.** Write to a temp name and
     rename only on successful completion, keyed by the content hash in the
     filename. An interrupted export that leaves a half-written chunk which the
     next run happily reuses is silent corruption, and it is the failure mode
     this whole feature is most likely to produce.
  7. **The cache needs a size bound and an eviction policy.** A 1080p export is
     on the order of gigabytes for a long timeline. Location should follow the
     existing cache convention (`$XDG_CACHE_HOME/vyper/...`, as the proxy cache
     note above intends) rather than the source directory, with LRU eviction and
     a documented cap.

  Related: the aliasing/GPU work in S1b/S1c makes this more valuable, not less
  -- a re-export after a one-second edit re-renders one second of GPU work
  instead of the whole timeline, which is the difference between an interactive
  and an unusable iteration loop. It also compounds the existing "HW-encode tail
  is cadence-sensitive" note above: chunking adds cadence boundaries to a
  cadence bug that is already open.

  The alternative worth pricing before building the encoded-chunk version:
  cache *raw* composited frames instead. It sidesteps concatenation, codec
  matching, rate-control resets, and audio priming entirely, and allows
  re-encoding with different settings from the same cache -- but raw RGBA is
  ~8 MB per 1080p frame, so it is only viable for short ranges or as
  short-lived scratch. The encoded-chunk design is the one that scales to a full
  timeline; the raw-frame design is much simpler and is the right choice if the
  real use case is "re-render after a tweak" rather than "export repeatedly".

  If ever picked up, start with a spike that answers the two questions that
  decide the design: (a) can `ffmpeg -f concat -c copy` of forced-keyframe
  closed-GOP chunks preserve exact frame count and A/V sync, and (b) how large
  is the per-chunk key in practice once the overlapping-timeline-set is
  computed. Both are cheap to test and either can invalidate the design.
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


---

## Export-path memory gate — FIXED, and now a member of `all`

`./scripts/gate.sh render_valgrind` runs the export worker under valgrind --
the check AGENTS.md 9b asks for on any change to the render path's ownership,
and which nothing exercised before, because every prior valgrind run was the
probe path and no probe renders. It was added while testing Step C and FAILED
on pre-existing leaks: 1,327,884 bytes definitely lost in 7 blocks, 262,347
indirectly, 487 errors from 137 contexts.

1. **262,627 bytes (280 direct, 262,347 indirect) -- `render_open_output`
   (render.odin:1468).** The diagnosis was "no `avformat_free_context` in the
   encoder teardown" and it was HALF RIGHT, which is the interesting part:
   `enc_cleanup` existed, was complete, and was **never called from anywhere**.
   The whole teardown had been written and simply not wired up, so every render
   leaked the muxer/encoder state and -- separately -- the file's AVIO buffer
   was never flushed, because `enc_cleanup` called only `avformat_free_context`,
   which per the vendored header does NOT close a `pb` that `avio_open2`
   created (that is the `AVFMT_FLAG_CUSTOM_IO` case, and this is not it). Both
   halves are fixed: `defer enc_cleanup(&e)` in `render_worker_run`, and an
   `avfmt.closep(&e.fmt_ctx.pb)` before the free. Deferred rather than
   hand-written at each return because the worker has ~20 returns, and a leak
   that only happens on the error paths is exactly what a manual unwind misses
   (AGENTS.md 1).
2. **1,327,105 bytes -- `open_clip_decoder_ex` (decode.odin:650) via
   `decode_asset_thumbnail` (media.odin:320).** Also half right. The caller DOES
   `defer clip_decoder_reset`, but the reset skipped `dec.dst` -- the
   `avutil.image_alloc` destination buffer -- so the decoder's own output buffer
   was never freed by anyone. Two further defects surfaced with it: the reset
   gated every free on `dec.opened`, which means "usable", not "acquired", so
   every partial-failure return in `open_clip_decoder_ex` (seven of them, after
   the format context, codec context, scaler and image are already acquired)
   leaked the lot; and `frame_cache_clear` used `clear`, which keeps the dynamic
   array's capacity, while `clip_decoder_reset` then wiped the struct with
   `dec^ = {}` -- the AGENTS.md 1 trap verbatim, orphaning the cache backing
   store (271 bytes per decoded clip). Fixed by splitting
   `clip_decoder_release_ffmpeg` out of the reset as pointer-test frees (so a
   decoder that never reached `opened` still releases), a deferred unwind in
   `open_clip_decoder_ex` cancelled on success, and `delete(dec.cache)`.
3. **Three small records in the TEST HARNESS, plus one in the import path.**
   47 bytes: `render_test_env`'s `strings.split` (render.odin:3268). 127 bytes:
   `media_frame_count`'s `strings.split_lines` (media.odin:144) -- that returns
   an allocated `[]string`, and a `for ... in` does not free it, worse when the
   loop returns early on the line it wants. 271 bytes: the frame cache above.
   All now `defer delete(...)`.

**Result: 0 definitely lost, 0 indirectly lost, no invalid read/write/free.**
Errors from 137 contexts down to 129 (the remainder is FFmpeg/Odin runtime
noise, which per AGENTS.md 9b is never gated on).

**`render_valgrind` is now in `gate.sh all`.** It was held out while red, on the
reason that a gate red for reasons unrelated to the change under test trains
everyone to ignore it -- which is right, and is exactly why the two fixes are
this commit rather than a later one. The leaks it exists to catch were all
reachable from the export path, which no other target in `all` executes, so
without it `all` never touches that code's ownership at all.
