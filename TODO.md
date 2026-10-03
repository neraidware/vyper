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

**Proxy legibility: half-resolution + retuned encoder (2026-09-29).** The
proxy was capped at `PREVIEW_W/H` (768x432) regardless of source, so a 1080p
clip was decimated to 1/4.5 of its pixels before it was ever seen, and the
glyphs and edges that make a frame readable were gone before the preview's own
downscale got to be the lossy step. `proxy_scale` now returns half the source
in each axis, snapped to even for yuv420p and never upscaling a small source.
The preview framebuffer is unchanged, so letterboxing stays idempotent — this
only changes how much detail survives to be scaled into it. Encoder moves to
libx264 `veryfast` (from `ultrafast`, which disables most of x264's quality
machinery and threw detail away faster than it saved bits) at crf 22 (from 26).

**The setting that actually governs quality on a normal host is the hardware
bitrate, not crf.** This host logs `[enc] proxy encoder: h264_vaapi`, so preset
and crf only steer the CPU fallback and the crf 22 request is a no-op here.
`PROXY_HW_BITS_PER_PIXEL` was the real lever and it was tuned at 768x432.
Re-measured at half-resolution (`VYPER_PROXY_PROBE`, 3s 1080p source, artifact
size and mean_abs against the decoded source frame):

| bpp | size | mean_abs |
|-----|------|----------|
| 0.06 | 458 KB | 1.7 |
| 0.10 | 740 KB | 1.3 |
| 0.12 | 879 KB | 1.2 |
| 0.15 | 1084 KB | 1.1 |
| 0.20 | 1431 KB | 1.0 |

0.15 is the point where the hardware path reaches the SAME quality as the
tuned fallback (libx264 veryfast/crf 22 measures 1044 KB at mean_abs 1.0) at
the same file size; the two encoders disagreeing on quality is the actual
defect, since a host that falls back to CPU should not get a better picture
than one that stays on the GPU. Past 0.15 the curve is flat — 0.20 buys 0.1
mean_abs for 32% more bytes, and every byte is paid again on the decode side
of every scrub.

**The cache key is derived from the settings, not versioned.** A proxy is a
pure function of (source, settings), so preset, tune, crf, gop, the scale
divisor and the hardware bitrate constant are all folded into the stem hash
(`proxy_settings_hash`). The first attempt here was a version number in the
filename, which is a trap: it is correct only if every future tuning of
crf/preset/scale remembers to touch a filename, and the day one does not, every
proxy already on disk keeps being served (they are still frame-count-valid, so
`proxy_valid_cache_hit` accepts them) and the change silently does nothing. The
encoder CHOICE (GPU vs CPU) is deliberately still excluded, keeping the
existing reasoning on `Proxy_Encoder`: both produce a valid artifact, and
keying on the choice would make the CPU fallback re-encode on every launch.

**A failing probe poisons the cache — found by mutation testing, not by
inspection.** `VYPER_PROXY_PROBE` cleans up its artifact at the end of a
PASSING run, but failures exit via `os.exit`, which calls `runtime.exit` and
runs no deferred procedure. The leftover file sits under a key derived from the
current settings, so the next run finds it, treats it as a valid cache hit, and
asserts against the previous run's broken proxy instead of building a fresh
one — a single failed run poisons every run after it. The probe now prints its
artifact path on every path and the gate target removes it whether the probe
passed or failed.

**`proxy_probe` had no gate target and is now in `all`.** Nothing ran this
probe, so the resolution rule had no coverage at all. It synthesizes its own
1080p source (not `$KEYED_SRC`, because half of 1080p is 960 and the old cap was
768 — at smaller sizes both round to the same even number and the check would
pass for the wrong reason) and asserts the ENCODED dimensions. **The first
version of that assertion was tautological** — it called `proxy_scale` to get
the expected size, so mutating `proxy_scale` back to the old cap still passed.
The expectation is now spelled out independently in the probe. Mutation-checked
both ways: reverting to the 768x432 cap fails with "proxy is 768x432, expected
half the source 1920x1080 -> 960x540", and the poisoned-cache path was verified
end to end (fail -> cache empty -> next run passes).

**Audio: wedge-heal crashed the producer on a full bridge ring (2026-09-29).**
`audio_device_push: ring could not take a whole block; producer cursor would
desync`, on a packaged build during a stressed session, right after
`[skew] d=-43.33s ... rsync=5(+2) prov=1 full=13(+13)`.

Root cause is a contradiction between two mechanisms, not a race. The producer's
ONLY backpressure signal is `audio_device_queued() >= max_queue`, and
`audio_device_queued` returns **0 whenever `clear_req` is set** — deliberately,
so the producer does not stall on audio that is about to be discarded. But
`audio_device_clear` only sets a flag; the ring is not actually reset until the
callback honours it, up to one period (~10ms) later. For that window the
logical queue and the physical room disagree, and the ring is still FULL.

The wedge watchdog is the direct path, inside ONE feed pass: audio.odin:1362
fires `audio_device_clear()` because the queue is at cap and prod is short of
target, then audio.odin:1380 — twenty lines later, same function — throttles on
`audio_device_queued()`, reads 0, and pushes into the ring it just decided was
overfull. `audio_ring_write` only comes up short when `acquire_write` returns
`avail == 0`, i.e. genuinely full, so the retry loop cannot save it and the
assert fires. The resync and stream-not-ready clear sites (1498/1614/1316) have
the same property.

Fix: enforce the assert's own precondition at the producer, right before the
push, where the exact block size is known — `if i64(push_frames) >
audio_device_available() { skip_full++; break }`. `audio_device_available` is
`ma_pcm_rb_available_write`, was already computed for the health report and
never used as backpressure, and is NOT subject to the `clear_req` special
case. Free space can only grow between the check and the write (this thread is
the only writer, the callback only drains), so one check is enough. Deferring
costs nothing: `next_frame` advances after the push, so breaking re-mixes the
frame next pass rather than dropping it. This also repairs the wedge heal,
which previously could not run to completion.

`audio_device_queued`'s lie is deliberately left in place — removing it would
retune seek latency, and it is now harmless because nothing trusts it as a
write-permission signal.

**Not reproduced on demand.** The wedge needs a full ring *and* prod behind
target, which took a 43s skew under load. Verified instead: 1148 pushes through
the modified site with 0 assertions (`VYPER_AUDIO_TRACE=1 VYPER_AUTOPLAY=…`),
and the guard is exactly the condition under which `audio_ring_write` returns
short. A probe for this would be timing-dependent and flaky; the user's session
is the real test.

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

- [x] S6. Geometry writes route to where the clip READS (the Alt-wheel/Alt-drag
      loss fix + "keyframe all modified"). **Why:** a clip has TWO homes for
      every geometry property — a resting field and a keyframe track — and
      `kf_sample_keys` ignores the resting field between the first and last
      key. So "write the resting field" is silently discarded exactly when the
      user reaches for a property they want to animate. The routing was a
      per-call-site discipline (every write had to remember `kf_auto_key`), and
      the two preview gestures did not remember: Alt+wheel and Alt+middle-drag
      moved the inspector numbers, moved nothing under the pointer, and made
      the clip jump when the playhead left the keyed span. The same defect hit
      the inspector's typed fields (seeded from the sampled value, committed to
      the resting field), the handle drag's start snapshot (scaled from a
      position not on screen), and preview-move's grab offset (clip jumped on
      press).

      **Step — `clip_geom.odin`, the chokepoint.** `clip_geom_get` reads the
      playhead value; `clip_geom_set` writes wherever the sampler READS, keyed
      on `clip_geom_keyed_at` (the sampler's own `active` result, not
      "is this property keyed somewhere"). Three cases: (1) a key is active at
      the playhead → write a key, **ignoring the auto-key toggle**, because a
      resting write there would be discarded while the gesture was still under
      the pointer; (2) keyed but inactive at the playhead (before the first key
      or past the last, where `base` rules) → auto-key extends the animation,
      otherwise the resting write is what the sampler reads, so both are
      non-lossy and the toggle keeps its meaning; (3) unkeyed → resting write
      plus a pending bit. A `clip_visible_at` guard keeps case 1/2 from minting
      keys on frames the clip does not cover. `Clip.geom_modified: u8` is a
      7-lane pending mask, session-only and deliberately not serialized: it is
      "edited since the last key", which is a UI state, not a project fact.
      Migrations: both Alt gestures, the crop-pan undo snapshot, `edit_commit`'s
      geometry fields (its no-op compare also had to move to the sampled value,
      or a commit of the number already on screen stamped a key), the handle
      drag's snapshot, `clip_geom_drag` replacing `autokey_gesture` for every
      geometry lane, and preview-move's grab offset. `autokey_gesture` survives
      for gain, which is not a geometry lane. Read-side: the inspector's seven
      readouts, the group/field diamonds' values, and the prop-field focus seed
      all go through `clip_geom_get`, so the number on screen is the number the
      preview draws.

      **Step — the button.** `clip_geom_key_all_modified` keys every pending
      lane at the playhead in ONE undo node, sampling all values BEFORE writing
      any key (the first `kf_geom_set_lane_key` can unwrap a packed section,
      which changes what later reads resolve to). Lanes are keyed individually
      rather than by section: a pending set is routinely a subset, and folding a
      partial set would convert untouched lanes' scalar tracks for no reason.
      Returns the lane count so the caller can report a real result. The
      inspector row names the pending lanes ("Key X, L") instead of saying
      "modified" and hoping — a button that keys "whatever changed" is a button
      nobody trusts enough to press. The diamond is drawn dim
      (`KF_DIAMOND_FILL_DISABLED`) with nothing pending, not a lit no-op.

      **Probe (`geom_key_probe`, in `all`):** Alt+wheel and Alt+drag write where
      the clip is actually read — sampled inside the keyed span, baseline
      outside it, resting edit preserved when unkeyed, a neighbouring key reached
      by the curve, a keyed clip's visible value still responding with auto-key
      OFF, an un-keyed clip's panned lanes becoming pending, the button keying
      exactly the pending set (and not `scale`, which a pan never touched), a
      second press keying nothing, no key minted off-clip while the edit stays
      visible and pending, the button refusing to act off-clip and becoming
      actionable again on return, a manual lane key and a manual group key each
      clearing their own pending bits, and the typed-edit path changing what
      the preview shows without stamping a key on a no-op commit. Verified it
      FAILS on the pre-fix gestures, on the pre-fix typed-edit commit, on the
      unguarded off-clip button, and on a lane key that left its pending bit
      set, so it is not a probe that merely agrees with the implementation.
      `ui_probe` additionally
      pins that the row and its diamond get real layout boxes and that the
      pending labels read "X, L" / "none".

      **Two guards the button and the diamonds needed.** Both were found by
      reading the finished code back rather than by a failing test, so the
      probe cases for them are new and were verified to fail against the
      pre-fix behavior:

      - **Pending is not the same as actionable.** `clip_geom_key_all_modified`
        writes keys AT the playhead, and `clip_geom_set`'s `clip_visible_at`
        guard exists precisely so no edit can mint a key on a frame the clip
        does not cover — so the button was routing straight around that guard,
        and a click with the playhead off-clip would mint an off-clip key. New
        `clip_geom_can_key_all_modified` (pending AND playhead-on-clip) is what
        the click handler and the dimmed diamond consult; the proc itself
        asserts, so a caller that skips the guard crashes instead of quietly
        keying frame 340. Off-clip the pending set **survives** — the edit is
        real, just not keyable at a frame where the clip has no pixels.
        (`kf_add_prop` and `kf_add_group_prop` already clamped into the clip, so
        this was the only unguarded path.)
      - **Keying a lane and marking it keyed are one action.**
        `clip_geom_add_lane_key` / `clip_geom_add_group_key` are now the only
        way the inspector's geometry diamonds key anything: a lane panned and
        then keyed by hand is no longer pending, and the eight call sites had
        been leaving the bit set, so "Key X" stayed lit and re-keyed the lane
        on the next press. The group wrapper takes the section NAME and reads
        its lane list from `kf_geom_sections` — the same table
        `kf_geom_set_packed` reads the payload in — instead of the seven values
        being spelled out positionally at each call site, which was a
        hand-written parallel copy that a new lane would have silently
        misplaced. The gain diamond is not a geometry lane and still calls
        `kf_add_prop`.
      - **The handles were the last un-routed geometry write.** The drag
        writes the RESTING fields every frame — the gesture is not committed
        until the pointer is released — and that is precisely the write
        `kf_sample_keys` discards between the first and last key of a span. So
        on a keyed clip the handles appeared to work (the inspector numbers
        moved, the preview redrew) and animated nothing, with auto-key off. The
        mouse-up path now calls `handle_drag_commit`
        (`preview_transform.odin`), which runs the same `clip_geom_drag` the
        other gestures use: a keyed lane is keyed at the playhead, an unkeyed
        one goes pending for the inspector row. It lives beside
        `begin_handle_drag`/`update_handle_drag` so the gesture's whole
        lifetime reads in one place AND the probe can drive the shipped call
        instead of re-declaring the lane list — a copied list would keep
        passing if the real call site stopped routing a lane. Crop stays gated
        on `handle_drag.kind` so a corner handle does not stamp keys on the
        edges it never reached.
      - **Auto-key no longer unwraps a packed section.** "Extend the animation
        that is already there" and "give this property its own track" both
        arrive as a lane write, and only the second should rewrite the section's
        shape — but they shared one proc, so a user who keyed crop as a single
        whole-crop section found it split into four per-lane tracks because they
        dragged one edge with the toggle on. `kf_geom_set_packed_lane_key`
        (render.odin) writes one lane onto the section's packed track under a
        single-bit mask, which is the form `kf_sample_packed_lane` is built for:
        a knot that does not cover a lane is not a breakpoint for it, so the
        other lanes keep their own curves. Both auto-key sites route through it —
        `kf_auto_key`, and the `clip_geom_set` branch that every shipped
        geometry write lands on (drag, Alt+wheel, typed field). A key already ON
        the frame is **merged** into, not replaced: `kf_set_packed_key`'s
        same-frame path overwrites mask and value wholesale, which would drop
        the other lanes out of a full-mask knot the user placed themselves.
        Unwrapping is unchanged where it is the user's actual intent — the
        inspector's per-lane Key button, and a typed readout value.

      **Accepted by:** `check`; `geom_key_probe`; `transform_probe`; `probe`
      (ui_probe, incl. the new row-layout asserts); `timeline_probe`;
      `keyed_export` (1.0x PSNR inf, 0.5x 58.7 dB — the export compositor
      shares the geometry sampling, so this is the parity guard); `smoke`;
      `gpu_composite`; `gpu_nv12`; `gpu_probe`; `zorder`; `yuv_exact`;
      `subtitle_probe`; `geom_key_valgrind`; `valgrind`; `render_valgrind`.

      **Found along the way:** `if !clay.UI(id)(config) { return }` produces an
      element with a **zero-height box** — Clay defers `_CloseElement` to
      `UI_WithId`'s natural end, and the non-block shape collapses the row.
      `draw_kf_add_buttons` skips zero-size boxes, so the button would have
      silently not existed. Use the `if clay.UI(id)(config) { ... }` block form
      the rest of `ui.odin` uses. Recorded because nothing reports it.

      **The memory gate was passing while measuring nothing.** Wiring
      `geom_key_valgrind` was supposed to prove the probe's new frees. Instead
      the target printed "ok" immediately — and so did the pre-existing
      `valgrind` and `render_valgrind` targets, for the same reason. Root
      cause: `-microarch:native` lets LLVM emit AVX-512, and Valgrind's VEX
      cannot decode it, so `./vyper` died with SIGILL in
      `math_big::initialize_constants` during `__$startup_runtime` — **before
      main, having allocated nothing**. Memcheck then dutifully reported
      "definitely lost: 0 bytes in 0 blocks", and all four invariants hold
      trivially for a process that never ran. Three fixes, in order of how
      much they mattered:

      1. **A Valgrind-compatible binary** (`vyper-valgrind`, built by
         `build.sh` from the same flags via `VYPER_OUT`/`VYPER_MICROARCH`/
         `VYPER_DEBUG` — §10, no duplicated `odin` invocation), at the baseline
         x86-64 target. `require_fresh_valgrind_binary` builds it on demand,
         which `require_fresh_binary` deliberately refuses to do: there, an
         implicit rebuild would hide "I meant to measure the previous build";
         here the binary has different flags, so a missing one is not a
         measurement anybody could have meant to make.
      2. **A non-vacuity assertion in `valgrind_assert`**, since that is the one
         place every memcheck target passes through and the place that decided
         "ok" on a dead process: the probe's own success line must appear, and a
         log containing "Unrecognised instruction" is a failure. A run that
         died early satisfies all four leak invariants for free, so this check
         is what makes the other three mean anything.
      3. **Frame pointers** (`VYPER_DEBUG=1` → `-debug`) for the gate build.
         The release build omits them, so every allocation trace came back as
         `calloc <- runtime::heap_allocator_proc <- ??? <- ???` — no better
         than no trace. With them, the first real leak named its own source.

      (2) immediately paid for itself: it caught a regression in the very fix
      below, which the leak counts alone had passed over.

      **A real leak it then caught:** `edit_begin` formatted the field seed with
      `fmt.aprintf` and copied the result into `edit_state.chars` — a heap
      string per property focus that nothing owned, so every click on a property
      field leaked 23 bytes (§1: format into fixed buffers, never
      `aprintf`). Now `fmt.bprintf(edit_state.chars[:], ...)`, which is
      allocation-free because the builder is backed by the array with a nil
      allocator. Note the full slice, **not** `[:0]`: `builder_from_bytes`
      takes its capacity from `len(backing)`, so `[:0]` hands it zero capacity
      and every format overflows. That capacity is also why the buffer may be
      passed un-clamped: 64 bytes covers the worst case (an f32 at two decimals
      is 43 characters), and the nil allocator panics on overflow rather than
      truncating — so a truncated field, which would silently show a number the
      preview is not using, is a crash instead.

      **A passing probe should shut down normally.** The dispatch used
      `os.exit(geom_key_probe_run())`, which skips the runtime's teardown, so
      the thread/TLS allocations the runtime frees on a normal exit were still
      live when memcheck took its census. `main` returns nothing, so a non-zero
      code needs `os.exit` — but a *passing* probe now `return`s out of `main`
      and lets the runtime tear down; only a failing probe exits immediately,
      where the non-zero code is the gate's pass/fail signal anyway.

      Also made `build.sh` skip a shader whose `.spv` is already newer than its
      source: recompiling unconditionally bumped `.spv` mtimes on every build,
      and `require_fresh_binary` rightly treats a fresh `.spv` as "the binary
      is stale" — so building the Valgrind binary knocked `./vyper` out of date
      even though no shader had changed.

      Measured after the fix, on the baseline binary: `geom_key_valgrind` 0
      definitely lost / 0 indirectly lost, 61 errors from 32 contexts; `valgrind`
      0 / 0, 11643 errors from 22 contexts; `render_valgrind` 0 / 0, 478 errors
      from 128 contexts. The context counts are the noise baseline AGENTS.md
      §9b asks to watch, and they are now recorded from runs that actually
      executed. Re-measured after the handle-drag commit landed: `geom_key_valgrind`
      0 / 0, 72 errors from 43 contexts. Every frame in that run is `calloc` (39),
      `malloc` (3), or one `runtime::conditional_mem_zero` reached through
      `_append_elem` when a key is added — the same Odin/FFmpeg noise class as
      the 32, not a new source. The delta is the new probe case's own
      allocations (the Clay arena the handle math needs, plus two more keys),
      and the probe needed Clay live for the first time: `preview_view` ->
      `clamp_preview_camera` reads element bounding boxes, and `main.odin`
      dispatches probes before its own `clay.Initialize`, so the probe now
      initializes it the way `transform_probe` already did. Re-measured again
      after the auto-key/packed-section fix: 0 / 0, 78 errors from 45 contexts,
      every frame still in the same class (41 `calloc`, 3 `malloc`, 1
      `runtime::conditional_mem_zero` through `_append_elem` when the packed
      key is inserted). **Found while verifying that fix, still open:**
      `VYPER_KEYFRAME_PROBE` is dispatched by `main.odin` but has **no target in
      `scripts/gate.sh`**, so the keyframe system's own regression suite — the
      right guard for packed-vs-lane writes — never runs in `all`. It passes when
      invoked by hand, but nothing keeps it that way. **Known and still open:** `VYPER_TL_PROBE` reports 79 bytes in
      1 block definitely lost — pre-existing, not reached by any valgrind
      target in `all`, and the frame-pointer build now makes it diagnosable.

      **The bounds box was still reading the resting fields.** Every write
      path was fixed to route through `clip_geom_get`/`clip_geom_set` at the
      playhead, but `clip_image_bounds` — the rectangle the selection border,
      the eight handles, and the clip hit-test all measure against — still read
      `clip.transform_x/y`, `clip.scale`, and `clip.crop_l/r/t/b` directly,
      while the image *inside* that rectangle is drawn from the sampled preview
      slot. So on a keyed clip the handles sat on a box the clip was not drawn
      in: it looked correct until a handle was touched, and the drag then began
      from a corner nowhere near the visible pixels. Reads now go through
      `clip_geom_get` on all seven lanes, both the video and the text path,
      matching the rule `crop_viewport_zoom` already documented two functions
      below. **A second resting read in the same family:** `preview_state.odin`
      computed a text clip's raster *resolution* from `clip.scale` while
      `slot.scale` (sampled three lines earlier) drove the box it was measured
      against, so a title on a keyed scale animated its box but re-baked its
      glyphs at the base size — stretched and soft. Both quantities are the same
      scale at the same frame, so it now reads `slot.scale`. **Uncovered:** the
      `geom_key_probe` fixture is a `.Video` clip, so no gate exercises this text
      path — mutating it back to `clip.scale` leaves every gate green. Asserted
      by inspection (the sampled value is three lines above the use) rather than
      by test, and a text-clip case in that fixture is the fix if that is not
      good enough.
      **Remaining in this family, deliberately not touched:** the subtitle
      path (`update_subtitle_slot`) still reads `clip.scale` for its raster and
      then *writes* new `source_w/h` and a re-anchor back onto the clip. That
      is a different question: a read wants the playhead, but this write is a
      re-centring of the clip itself, and routing it through `clip_geom_set`
      would mint keyframes on every cue change. It needs an explicit decision
      about whether subtitle auto-fit is a keyed property or a resting edit, not
      a mechanical substitution.

      The regression asserts the *property* rather than a baked rectangle:
      `geom_key_probe` scrambles all seven resting fields and requires
      `clip_image_bounds` not to move, then puts a new scale key under the
      playhead and requires it to. The converse check is what stops a function
      that ignored both sources and returned a constant from passing. Verified
      by mutation: reverting `Trans_X` to the resting field and reverting
      `Crop_L` each fail the probe with the two boxes printed. Re-measured:
      `geom_key_valgrind` 0 definitely lost / 0 indirectly lost, no invalid
      access, 76 errors from 43 contexts — the same class as the 45 above, and
      no new context class.

- [x] S7. Multiple keyframe selection. **Why:** moving keyframes was a
      one-at-a-time ritual — arm a press on a diamond, slide it, re-press the
      next one. Anything longer than two or three keys (the usual case: a run of
      keys to retime, a whole ramp to re-ease) was a per-key click-drag, and
      every key it touched had to be slid the same distance by hand.
      `Keyframe_Selection` becomes a grow-only list of `Kf_Ref` (track/clip/
      lane/key) under ONE `structure_gen`, so the set invalidates together — one
      set/del can slide any key, and a per-key gen would let a half-stale
      selection resolve. It is a `[dynamic]`, not a bounded array: a cap would
      silently drop refs past it, and "the key I shift-clicked is not selected"
      is a bug with no visible cause. Cleared with `clear` (which KEEPS the
      backing buffer) so growing it never reaches the allocator again.
      **Shift+click adds every diamond under the pointer** (`kf_keys_at`, the
      same `kf_key_center` geometry the paint and hit-test share) — adding is a
      union, not a toggle, because toggling a SET has no honest answer (which way
      does a press flip two keys when one is already in?). A plain click replaces
      the set, so over-selecting recovers in one click. No drag-select box yet.
      **The drag became a preview instead of a live write.** It used to assign
      `k.frame_off` in place every tick, which left the key arrays unsorted for
      the whole gesture and made the release's del+set a REPAIR of a scrambled
      array — it only landed right because `kf_set_key`'s same-frame replace
      happened to find the key it had just failed to delete. That is why two
      selected keys could not move together: the release could no longer tell
      which element was which. `Kf_Move` now records only the frame delta
      (`kf_move.delta`, recomputed from the press frame every tick, never
      accumulated) plus one `Kf_Snap` per selected key captured at press, and
      `draw_keyframes` paints each at `start + delta` via `kf_sel_frame`. The
      store is untouched until the release, so the arrays stay sorted and unique
      and del+set is a real normalization. The dragged curve also can no longer
      flicker in the preview, which re-reads the keys at the playhead.
      **The release runs ALL deletes before ANY set.** Two keys on one lane can
      trade frames; a set landing on a frame another key has not vacated yet is
      swallowed by the same-frame replace, and that key vanishes instead of
      moving.
      **A move now preserves `interp`.** `kf_set_key`/`kf_set_packed_key` insert
      with a zeroed `Kf_Interp`, so sliding a key silently straightened its
      easing to the `.Cubic` default — the release re-stamps the captured mode on
      the landed key.
      Operations on the whole selection: move (above), `Delete` (one `.Value`
      node), and the shared-property editor. **The inspector shows the
      genuinely-shared properties of a multi-selection, not a var identity:**
      interpolation is a property of a key wherever it sits, so the dropdown is
      offered whenever N keys are selected — showing the shared mode when they
      all agree and `-` when they do not, and writing all of them on a pick.
      The VALUE field is not offered for a multi-selection: it is a property of
      one key on one lane, so with keys on different lanes there is no number
      that means anything, and with keys on one lane the only "set all" would
      flatten the animation. The header shows the track name when the whole
      selection is on one lane and `N keyframes` otherwise, and the frame line
      the span. `kf_selected` now reports ok only for a selection of EXACTLY
      one key, so a multi-selection can never half-resolve into the first ref
      and then be edited as if it were the only one — the single-key callers
      (the value field and its click handler) get that for free.
      **Four defects the probe found, all fixed here rather than worked around.**
      (1) `kf_set_interp_all` opened the undo seam AFTER writing, so the pick was
      untracked: `undo_push` snapshots the POST-edit tree and folds the pending
      PRE-edit capture into the cursor's action, which is the only way the edit
      becomes undoable. Undo landed back on a state that already had the new
      interp — an undo that appears to work and redoes nothing. (2) The drag read
      its frame mapping from `snaps[0]`, which a Shift+click union can leave
      naming a DIFFERENT clip than the one under the cursor (the set is ordered by
      the older selection), so the delta was taken through another clip's box;
      `Kf_Move.anchor` is the grabbed key now. (3) The release and re-arm paths
      `clear`ed the capture list, but each `Kf_Snap` owns a cloned track name —
      one leaked string per selected key per drag; `kf_snaps_drop` frees the names
      and keeps the buffer. (4) `undo_free_all` freed every snapshot but not
      `Undo_Node.label`, and `undo_init` seeded a LITERAL `"start"`, so a session
      leaked one label clone per recorded edit and the literal was the reason the
      delete was missing. Also fixed while under the memory gate:
      `kf_del_key` dropped an emptied track with `ordered_remove` after `pop`,
      which shortens without releasing, orphaning that track's key array for the
      life of the process; and the probe seeded a live session it never tore down
      (the ui probe has called `session_teardown` all along — the undo probe did
      not, which is why the tree read as lost).
      **The undo probe now has a memory gate of its own**
      (`scripts/gate.sh undo_valgrind`, in `all`). `target_valgrind` runs the UI
      probe, and the undo probe is where the keyframe-capture lifecycle lives
      (a cloned name per key per gesture, re-armed every press), so no existing
      target measured any of it. Baseline on the pre-S7 tree: 372 bytes in 13
      blocks definitely lost. After the four fixes: 0 in 0.
      Gates green: `check`, `build`, `probe`, `transform_probe`, `geom_key_probe`,
      `timeline_probe`, `geom_key_valgrind`, `valgrind`, `undo_valgrind`, plus
      `VYPER_KEYFRAME_PROBE` and `VYPER_RENDER_KF_PROBE`. `scripts/gate.sh build`
      now delegates to `./build.sh` instead of re-declaring the link flags — it
      had lost the `--sysroot`/`-l` list and failed at the LINK step, a long way
      from the cause (§10).

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
- [x] S1. Add an opt-in headless export benchmark fixture for scale `1 -> 2`,
      `1 -> 3`, constant scale, transform-only, crop-only, reversed scale, and
      off-canvas motion. Record wall time, producer time, keyed `sws`, stage
      dimensions, output frame count, and a reference-frame hash/PSNR.

      **Status: landed (`de0e1b7`), `scripts/gate.sh export_bench`.** Seven
      shapes, opt-in and deliberately NOT in `all` -- it measures, it does not
      gate, and a perf target in the suite fails on a busy machine.

      Two things it does that the old single-shape numbers could not:

      - **The stage is reported next to the timings.** A keyed animation
        decodes a stage sized from the *peak* scale and then crops it, so
        `1 -> 2` builds 3840x2160 and `1 -> 3` builds 5760x3240 for the same
        1920x1080 canvas. `render_max_stage_w/h` records the max across clips at
        job setup. The canvas size alone hid this completely, and it is what
        makes ms/frame between the two shapes incomparable. `off_canvas`
        reporting `stage 0x0` / `producer 0.00` is the correctness check on
        that accounting: a fully off-canvas clip never decodes.
      - **The md5 ties each timing to pixels.** Two consecutive runs hashed
        identically for all seven shapes, so a changed hash now means the render
        changed and the timing is not comparable.
      - **There is no `sws`/resample column, on purpose.** S1c composited
        keyed frames straight into the GPU canvas, so `render_eval_keyed_geom`
        returns before the separate resample and `comp_resample_ns` is
        structurally `0` for every shape -- the cost moved into the composite
        walk. A permanently-zero column is a lie with a number in it, so the
        columns are the ones that still move.

      **It also settles the `nv12 wait` question that the single-shape numbers
      left open.** Reverting S1c in place and running the same seven shapes
      through the same tooling:

      | shape | before `cpy`/`pack`/`wait` | after `cpy`/`wait` | wall before -> after |
      |---|---|---|---|
      | `scale_1_to_2` | 0.86 / 22.32 / 3.13 | 0.34 / 3.25 | 2.92 -> 1.92 |
      | `scale_1_to_3` | 0.86 / 22.44 / 4.19 | 0.34 / 4.52 | 4.02 -> 3.91 |
      | `scale_reversed` | 0.89 / 22.50 / 3.78 | 0.36 / 3.88 | 2.97 -> 1.91 |
      | `scale_constant` | 0.84 / 22.57 / 2.88 | 0.21 / 2.83 | 2.92 -> 2.01 |
      | `transform_only` | 0.75 / 22.20 / 1.63 | 0.24 / 2.87 | 2.56 -> 0.61 |

      All seven md5s are identical before and after, so this is a like-for-like
      comparison of the same pixels. **`wait` is not a regression**: it is a GPU
      fence that varies 3.25-3.63 ms run-to-run (11% spread) on identical input
      *and* identical output hashes, and the matched before/after pairs sit
      within 0.4 ms on all four keyed shapes. The earlier "2.31 -> 2.72-3.08"
      reading was one sample against that whole spread. It also tracks GPU work
      rather than the pack -- the biggest stage (`scale_1_to_3`) has the largest
      `wait`, and `crop_only`, which takes the CPU fallback and never touches
      the GPU, has `0.00` on every field. What S1c actually removed is 22 ms/f
      of pack and half of `cpy`, and `cpy` is the stable number (0.25-0.36).
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

      **The byte-exact gate this step depends on now EXISTS and is green
      (2026-09-27).** `yuv_exact.odin` is a CPU RGBA->NV12 ground truth that
      matches swscale with ZERO mismatches at every even size tested
      (8/16/32/64/96/128/160/256), and `yuv_exact` is a gate target in `all`.
      That is the prerequisite the entry above named: once preview and export
      share the conversion, `keyed_export`'s 1.0x `PSNR=inf` anchor goes blind
      to it, so a direct byte-for-byte comparison has to carry that job instead.
      It compares swscale against the same code the shader will be written
      against, and it is proven to fail: a one-unit change to `YUV_REF_BU` turns
      it red.

      Getting there took four corrections, three of which were mine and none of
      which were visible in the output until measured:

      - **The dither table is not zeros.** `yuv2nv12cX_c` seeds its accumulator
        with `chrDither[i&7] << 12`, and with dithering off that table is
        `sws_pb_64` = {64,64,64,64,64,64,64,64}. "pb" is plus-bias. So there is
        a standing +262144, which is exactly half a byte after the `>>19` --
        the output is round-to-nearest on P, not a truncation. I had read it as
        a zero table, which is the obvious assumption from the name AND from the
        dithering path that really is zero. This was the entire half-byte.
      - **The vertical filter is `[1,3,3,1]/8`, not `[2,7,7,2]/18`.** Measured,
        not guessed: with `P` exact and `flat` at 0, the four taps were solvable
        from a y-only ramp, and least squares kept returning ~(1015,3080,3077,1020)
        -- asymmetric, which ruled out any symmetric kernel, and close to
        (1024,3072,3072,1024) = `[1,3,3,1]/8`. The earlier impulse reading of
        `[2,7,7,2]` was taken while three other stages were still wrong, and
        0.111 and 0.125 round to the same byte at that contrast.
      - **The chroma coefficients were mis-transcribed.** Computed the way the C
        does they are RU=-4865 GU=-9528 BU=14392 RV=14392 GV=-12061 BV=-2332;
        I had -4862/14393/-12059/-2329. Luma (8414/16519/3208) was right, which
        is why luma was byte-exact from the start and masked the error.
      - **NV12 chroma is byte-interleaved `U,V,U,V`, not two planes.** The
        original probe read it as contiguous U then V, which produced a phantom
        asymmetric "kernel" and sent the whole search after a bug in the arbiter.

      The lesson worth keeping: every one of the four was found by a probe that
      disagreed, not by reading the source. Two of them (the coefficient
      transcription, the `[2,7,7,2]` reading) looked entirely plausible and
      survived several rounds of measurement because the error was inside the
      noise of a weak test -- a 3-unit coefficient error is invisible against
      64-wide quantisation buckets, and 0.111 vs 0.125 differs by one output
      LSB. Isolating ONE axis per run (`flat` collapses the vertical filter,
      `vgrad` collapses the horizontal) is what made each error separable, and
      that is why the probe kept all three modes.

      Domain: even dimensions only, asserted. 4:2:0 has no odd chroma grid and
      the target encoders reject odd sizes. For an odd dimension swscale
      silently changes its horizontal chroma siting rather than erroring --
      measured, 77-7830 mismatches -- so the reference asserts instead of
      returning quietly wrong bytes. That is the one case here that is a stated
      limit rather than a solved one.

      **The GPU half is now byte-exact too (2026-09-28).** The conversion runs
      on the GPU (shaders/nv12_luma.frag + nv12_chroma.frag) and matches
      swscale AND the CPU reference on every byte, at every even size
      8/16/32/64/96/128/160/224/256 -- gpu_nv12 is a gate target in `all` and
      proven red on drift (RY off by one turns it red). It draws two fragment
      passes into RGBA8 targets -- one for luma, one for interleaved chroma
      rendered at size/2 -- then packs the two planes into NV12. RGBA8 targets
      rather than R8/RG8 because R8/RG8 color-attachment support is
      driver-optional in Vulkan; the unorm8 quantization is identical either
      way. Two details are doing real work in the shader math and both are
      NON-obvious, so they are commented at the source:

      - The whole chain is int32, and the roundings happen at the SAME points
        swscale's do (input.c rounded luma at 15 bits, chroma P at 10, the
        vertical stage at 19 with the standing +262144 plus-bias). A plausible
        float 0.299r+0.587g+0.114b shader that rounds once at the end is wrong
        on roughly half the samples, because it collapses three different
        roundings into one.
      - The chroma reduction is NOT "average pixels then subsample": swscale
        computes a 15-bit P for each LUMA ROW (that is the P u0..u3 the
        [1,3,3,1]/8 vertical filter consumes), and P is rounded per row. A
        separable blur that averages 2x2 after filtering gives different bytes.
        The shader reproduces the row-P ordering exactly.

      The two measurements inside the probe deserve a note. (1) The download
      buffer was once sized in NV12 bytes (w*h + uv_w*uv_h) while each plane
      costs 4 bytes/pixel; the driver wrote past it and the frame read back
      "right for the top quarter, garbage below" -- hindsight, the buffer
      exactly fit three luma rows. (2) V came back as 0 at EVERY sample while
      U stayed exact, from reading the blue channel rather than green in the
      pack; the signature of a packer bug (one channel dead) is distinguishable
      from a shader bug (everything dead) by exactness of the surviving
      channel. Both are per-byte-class failures a single `mismatches = 0`
      gate had to catch on first brush, and did.

      **The composite contract is proven (2026-09-28).** The per-clip quad
      draws into one GPU canvas reproduce render_blit_region's z-order,
      clipping, and offset placement byte-for-byte: gpu_composite is a gate
      target in `all`, and it is proven red on a dropped z-order op (skip the
      op-4 draw and the pixels it owns fail exact). The ops sequence is hostile
      on purpose -- 1:1 sub-rect copies, a 2x box downscale, a right-edge
      clipped copy, a copy that over-writes the downscale, a left-clipped
      downscale over that, and a nested over-write -- and the per-pixel
      topmost-op mask is why a reorder is caught, not just a missing draw.

      Two bounds were measured, not chosen. (1) The down regions use INTEGER
      2x ratios because the GPU and CPU box kernels pick their integer tap sets
      by different rules and only agree to ~0.1 mean there: at 64:24 the shader
      always takes ceil(2.67)=3 taps while the CPU span count alternates
      2/3, which is a full 5-6 mean on a changing image. That is a resample-
      quality question that gpu_probe already owns, so this gate keeps the
      ratios where the two align and the composite's OWN behavior is what gets
      measured. (2) The `flat`/`vgrad` lesson repeated here: a LCG stage made
      the kernel pair disagree hugely (11.3 mean) because independent per-byte
      noise is the worst case for tap-count differences; correlated video-like
      content is what both kernels actually process, so the probe uses a smooth
      deterministic pattern instead.

      **What this unblocks:** the export worker can now replace the CPU
      canvas (render_blit_region calls + the kres_scratch round-trip) with one
      GPU canvas texture, drawn in the same z-order the CPU walk used, with a
      byte-exact contract on every pixel the exporter's own rule says must be
      exact. The piece that remains is the plumbing itself: run these passes in
      the render worker's frame loop and hand the surfaced NV12 to
      hw_frames_ctx -- the correctness questions are all gated now.

      **What this unblocks:** the conversion is now replaceable end-to-end
      inside the export path (GPU composite -> shader -> pad/merge into the
      encoder's w/h NV12 buffers) with a byte-exact contract rather than a
      quality guess. The remaining S1c work is the *plumbing*: composite the
      keyed/static z-order into a GPU canvas instead of kres_scratch, call
      these passes on it, and hand the result to hw_frames_ctx -- each is a
      structural change with its own gate, not an open correctness question.
- [x] S1c. GPU composite straight to canvas, then GPU RGBA->NV12 handed
      directly to `hw_frames_ctx`. S1b still round-trips each keyed resample
      through `kres_scratch` and a CPU `render_blit_region` because keyed and
      static clips interleave in z-order, so compositing on the GPU needs
      either a reordering that preserves overlap semantics or one composite pass
      per clip into a GPU canvas. Dropping the readback is what removes the
      upload/download cost that currently caps the win at ~5x rather than the
      probe's 8-10x.

      **PART 1 LANDED 2026-09-28 — GPU canvas composite, one readback.**
      The worker now composites the whole video visual stack into one GPU canvas
      texture (render_gpu.odin `GPU_Composite` begin/draw/end) and reads it back
      once per frame into the encoder slot, replacing the per-keyed
      stage-upload + resample + readback round trip and the CPU
      `render_blit_region` for static 1:1 clips. Keyed and static clips draw in
      the same back-to-front z-order the CPU walk used; the first draw's CLEAR
      is the background fill (skips mem.zero). The CPU canvas is the drop-in
      fallback, selected up front when the job has a text clip, a subtitle clip,
      or a crop-scaled static clip (needs swscale bilinear; its kernel differs
      from blit_box on sub-pixel crops), or when the GPU device is absent;
      `VYPER_KEYED_GPU=0` pins it for the A/B. `render_gpu_abort` latches a
      mid-composite driver failure so the run stops instead of encoding a
      partial frame.

      **Gated by the existing `keyed_export` A/B, which now compares
      GPU-composite against CPU-composite:** 1:1 PSNR `inf` (byte-identical),
      0.5x 58.71 dB -- the same value as the previous GPU-resample-vs-CPU A/B,
      so the canvas path changed no shipped bytes. Proven red: a +1 px dst
      drift drops 1:1 off bit-exact (`1:1 is not bit-exact`) and 0.5x to
      34.9 dB. `zorder` passes unchanged (text clip -> CPU fallback). Composite
      time at 1:1 dropped 3.14 -> 2.42 ms/f (one readback against per-keyed
      round trips); valgrind clean.

      Remaining under this bullet: run the gated RGBA->NV12 passes on the canvas
      (no readback) and hand NV12 directly to `hw_frames_ctx`.

      **PART 2 LANDED 2026-09-28 — GPU RGBA->NV12 on the canvas; encoder
      skips swscale.** The worker now converts the composited canvas to NV12 on
      the GPU inside `gpu_composite_end_nv12` (two passes, luma w*h + chroma
      w/2*h/2, sequencing the existing gated shaders against the canvas) and
      packs the two planes into the encoder slot's `nv12` buffer, setting
      `slot.nv12_ready`. The encoder thread branches on that flag and sends the
      packed bytes via `rend_enc_video_frame_nv12` -- no swscale, no
      `frame.data` reshape; `rend_enc_send_video` (the frame-wrap/hw-upload/
      send/drain tail extracted from the CPU path) is shared by both. Selected
      when the NV12 encoder + even dimensions + GPU composite are all live;
      `VYPER_GPU_NV12=0` pins the encoder-side swscale for the A/B. The pack
      reads RGBA8 planes at 4-byte strides, so `gpu_composite_end_nv12` first
      copies the mapped download sequentially into a worker-job-arena scratch
      (`render_pipe.gpu_nv12_scratch`): strided reads straight off the
      device-visible map measured 12.5 ms/f, the copy-then-pack ~1 ms.

      **Gated by the same `keyed_export` A/B, now the FULL chain:
      GPU-composite + GPU-NV12 against CPU-composite + swscale:** 1:1 PSNR
      `inf`, 0.5x 58.71 dB -- unchanged, so the new conversion shipped zero
      diff against swscale. Proven red: swapping U/V in the pack drops 1:1 off
      bit-exact and 0.5x to 17.8 dB. `zorder` passes. Debug-build timing
      (bounds-checked scalar pack, 22 ms/f) is an artifact of the gate's
      `-debug` binary; the release build measures pass=0.02 dl=0.01 wait=2.31
      cpy=0.91 pack=0.82 ms/f. Valgrind clean (scratch + slot nv12 are escaped
      job-arena bytes).

      **PART 3 -- the zero-copy premise is FALSE for FFmpeg 9, and that is now
      measured, not assumed.** The plan this entry used to carry was to export
      our own `VkImage` as a dmabuf and hand it to the encoder. It cannot be
      built, and all three legs were checked against the library rather than
      reasoned about:

      | route | verdict |
      | --- | --- |
      | inject a caller-supplied image/fd into FFmpeg | no API at all |
      | `av_hwframe_transfer_data` VULKAN->VAAPI | `-38` ENOSYS (probe) |
      | render into FFmpeg's own Vulkan frame | no image handle exposed |
      | get the `VkImage` out of SDL_GPU | handles are opaque |

      Leg by leg: `av_hwframe_ctx_set_extra_hw_frames` is not exported by
      `libavutil.so.61` at all, and `extra_hw_frames` is gone from
      `hwcontext.h`. Worse, `AVHWFramesContext` is now OPAQUE -- only the
      fields through `height` are public -- so `buf[]` is unreachable even by
      hand-writing offsets, which also kills the struct-mirror trick. The
      public hwcontext surface is 18 symbols and none takes a buffer. A Vulkan
      frames context initialises fine and hands back frames, but
      `AVVulkanFramesContext` exposes only `format[]`, `usage` and
      `lock_frame`/`unlock_frame` -- there is no `img[]` or any image handle,
      so those frames are write-only-to-the-encoder and readable out only via
      `av_hwframe_map_data`. And a direct transfer probe between a real Vulkan
      and a real VAAPI frames context returns `-38`, so there is no GPU->GPU
      path either. On the SDL side, `SDL_GPUTexture` and `SDL_GPUDevice` remain
      opaque forward declarations (`SDL_gpu.h:473`, `:411`); the
      `SDL_GPUVulkanOptions` extension list only lets us *require* extensions
      on SDL's device, which was never the obstacle -- the opacity is.

      **So `av_hwframe_transfer_data` is not an inefficiency to be tuned away.
      In FFmpeg 9 it is the only supported door, and the CPU round trip is
      load-bearing.** Every zero-copy design is off the table, and
      `h264_vulkan` is not a way back either: it is a Vulkan-std SOFTWARE
      encoder, so trading `h264_vaapi`'s hardware path for it to save a copy is
      a throughput bet that was never measured and need not be taken.

      **What is left is the part that was actually wasteful, and it is not the
      transfer -- it is converting the image TWICE.** The chain currently
      converts on the GPU into `R8G8B8A8` targets (U in `.r`, V in `.g`, luma
      in `.r`), downloads 8 MB of RGBA per 1080p frame, and then runs two CPU
      loops that pull the luma from every 4th byte and interleave the chroma
      pair -- re-deriving on the CPU the very bytes the GPU just computed. That
      is `cpy=0.91` + `pack=0.82` ms/f, and the 8 MB download exists only to
      throw 5 of every 8 bytes away.

      **PART 3 LANDED 2026-09-29 — the GPU now emits NV12 memory directly, and
      the CPU no longer converts anything.** Two `R8` targets: luma `w x h`, and
      chroma `2*uv_w x uv_h`, where the shader puts U and V in ADJACENT texels
      (even x -> U, odd x -> V) rather than in the `.r`/`.g` channels of one
      RGBA pixel. That parity rule is the only new logic in the change, and it
      is what lets a single-channel target hold an interleaved plane. Both
      downloads are then already contiguous and in NV12 order, so the transfer
      buffer receives the finished frame and one sequential copy lands it in the
      encoder slot. Deleted: the `cpy` scratch, both pack loops, the
      `comp_nv12_pack_ns` timer, the `GPU_Composite.scratch` field, and the
      `5*w*h` `gpu_nv12_scratch` arena buffer (the slot's own `nv12` is already
      exactly `w*h*3/2`, so the scratch was the same bytes twice). The
      conversion now happens once instead of twice, and nothing on the CPU
      mirrors the shader's channel layout that could drift out of sync with the
      probe. `yuv_exact` gates the new R8 layout byte-for-byte against swscale at
      8..256 and in `flat`/`vgrad` modes; the chroma viewport is the TARGET
      width (`2*uv_w`), not the sample count, since the pass emits one texel per
      U or V byte.

      MEASURED, keyed 1920x1080 fixture, same binary type as the numbers above:

      | stage | before | after |
      | --- | --- | --- |
      | `cpy` (sequential copy out) | 0.91 ms/f | 0.23-0.25 ms/f |
      | `pack` (CPU interleave) | 0.82 ms/f | deleted |
      | bytes moved per frame | 10.4 MB | 3.0 MB |

      The deleted work is stable across runs; it is ~1.5 ms/f of CPU work and it
      scales with resolution, so it matters more at 4K than at 1080p. NOT yet
      claimed: `wait` (GPU idle after submit) samples 2.72-3.08 ms/f here against
      a single 2.31 ms/f sample from before the change. That is one old sample
      against a live spread, so it is a question, not a finding -- and it is why
      the perf acceptance below is deferred to S1's fixture rather than settled
      by these two runs.

      What this did NOT touch: the preview. The composite stays shared -- export
      and preview run the same `GPU_Composite` over the same canvas -- and the
      luma/chroma passes were already export-only, so no second renderer appeared
      and nothing forked. `g.down` keeps its old sizing because it is shared with
      the RGBA readback path, which still needs `w*h*4`. No FFmpeg API is
      involved anywhere in this part: no hwcontext, no Vulkan, no encoder swap.
      `h264_vaapi` stays hardware.

      ACCEPTED: `yuv_exact` byte-exact at 8/16/32/64/96/128/160/256 plus
      `flat:64` and `vgrad:64`; `gpu_nv12` ok; `keyed_export` 1:1 `inf` and 0.5x
      58.707992 dB, the committed numbers unchanged; `gpu_composite` byte-exact
      region; `zorder` `inf`/29.127371; `gpu_probe`, `probe`, `transform_probe`,
      `timeline_probe`, `subtitle_probe`, `smoke`, `check`, `shaders` all pass;
      `valgrind` 0 definitely lost / 0 indirectly lost, 11643 errors from the
      same 22 contexts as before the change, so removing the scratch neither
      leaked nor corrupted. The remaining perf question (`wait`) is S1's.

      **MEASURED 2026-09-27, and it reorders this work.** `VYPER_FRAME_TIME=1`
      on the 1920x1080 keyed fixture, 1:1 and 0.5x:

      | stage | 1:1 | 0.5x |
      |---|---|---|
      | composite | 1.34 ms/f | 5.60 ms/f |
      | **sws (CPU RGBA->NV12)** | **5.07 ms/f** | **5.27 ms/f** |
      | upload (NV12 into VAAPI surface) | 0.70 ms/f | 0.92 ms/f |
      | send | 0.23 ms/f | 0.25 ms/f |
      | drain | 0.03 ms/f | 0.03 ms/f |
      | decode producer (overlapped) | 1.76 ms/f | 2.07 ms/f |

      The CPU colorspace conversion is the single largest item in BOTH regimes
      -- 5.07 of 6.04 ms/f of encoder time at 1:1 (84%), and 81% at 0.5x. It is
      also the only stage that does not scale with the resample ratio, because
      it is a pure RGBA->NV12 conversion at source size and is not a resample at
      all. The pipeline's assumed blocker (raw VAAPI interop, possibly a forked
      FFmpeg) is NOT where the time is: `enc_hw_upload_open` already gets a
      `hw_frames_ctx` and the "hardware" path still converts on the CPU, because
      the only missing link is the RGBA->NV12 pass. That pass is ordinary SDL GPU
      work and needs no interop and no fork. **So GPU RGBA->NV12 is the first
      step, ahead of the interop question, not after it.**

      **The gate consequence, which is the real constraint on that step.**
      `keyed_export` is an A/B of two runs of the SAME renderer --
      `VYPER_KEYED_GPU=1` (default) against `VYPER_KEYED_GPU=0` (the CPU
      resample kernel) -- PSNR'd against each other, so `1.0x PSNR = inf` means
      "the two RESAMPLE KERNELS agree byte-for-byte", and the swscale colorspace
      conversion is common to both sides and cancels out of the comparison.
      Moving RGBA->NV12 onto the GPU therefore does NOT threaten the `inf`
      anchor, because both sides would use the new conversion. What it DOES do
      is blind that gate to the conversion: a bug in the new pass would land
      identically on both sides and the PSNR would stay `inf` while the file is
      wrong. So stage one is only shippable alongside a NEW gate that pins the
      GPU conversion against what it replaces -- `enc_convert_rgba_fast` (the
      in-tree SIMD kernel) and/or swscale -- headlessly, bit-exactly, the way
      `gpu_probe` already pins the resample kernel. Exactness is achievable in
      principle but that is a claim to be MEASURED, not assumed, and two
      measured facts now bound it.

      **The in-tree CPU alternative is a dead end, measured.** `VYPER_YUV=1`
      (`enc_convert_rgba_fast` -> `yuvconv.rgba_to_nv12`) is 3.2x SLOWER than
      the swscale it would replace: 16.02 ms/f against 5.07 ms/f on the same
      1920x1080 fixture. So `enc_convert_finish`'s "off by default" is not
      conservatism about byte-exactness alone -- the default is also three times
      faster, which is the real reason to leave it off. The CPU floor here is
      swscale's ~5 ms/f with no cheap win below it. That is what makes the GPU
      the only route to a large win, rather than a preference.

      **swscale's RGBA->NV12 is a FILTERED conversion, which is the real
      constraint.** Read in the build source rather than assumed
      (`/tmp/opencode/ffmpeg9/libswscale`): `ff_get_unscaled_swscale` has NO
      unscaled rgb->nv12 converter -- the unscaled set is rgb<->rgb,
      rgb->planar-rgb, and yuv2rgb (the reverse direction). RGBA->NV12
      therefore goes through the general `ff_sws_init_swscale` pipeline: an
      `rgb24ToY` pass against the `ff_yuv2rgb_coeffs` table, `yuv2plane1_8_c`
      for Y at 1:1, and CHROMA at half resolution through the horizontal scaler
      (`hScale8To15` with `SWS_BILINEAR` coefficients) plus vertical
      subsampling, in 15-bit fixed point with a final clipping shift. So the
      chroma is NOT the plain 2x2 box average the in-tree kernel assumes --
      which is precisely why that kernel is "byte-different by design".

      Porting that to a shader means reproducing the coefficient table, the
      rgb24ToY fixed-point form, the bilinear chroma taps at 1:1->1:2, the
      15-bit intermediate precision, and the final shift -- several interacting
      stages where a near-miss is visually identical but not byte-identical.
      That near-miss is the exact failure the current comment warns about, so
      the route is a real choice and is now the open question:

      - **(A) Byte-exact port of swscale's filtered path.** Exported bytes do
        not move at all and every existing anchor keeps its meaning, `inf` stays
        `inf`. Cost is the port above plus a bit-exact probe, and it is
        genuinely fussy; a near-miss is invisible until bytes are compared.
      - **(B) Adopt the GPU conversion as the new reference** and pin it with a
        new gate holding it to a PSNR floor against swscale (>=55 dB say),
        keeping swscale as the fallback. Far cheaper and provably a negligible
        change -- but exported files DO change bytes at the colorspace step,
        which lands in an already-encoded timeline, not in a private refactor.

      (B) is the cheap win, (A) is the safe one. This needs an explicit call
      because the difference is a change to shipped output rather than an
      internal choice. **(A) WAS CHOSEN 2026-09-27. Progress on it, measured
      with `yuv_exact_probe.odin` (`VYPER_YUV_EXACT_PROBE`):**

      **Luma is DONE and exact.** Fitting the coefficient triple and offset
      against 65536 random pixels pins the offset interval to a single value:
      `Y = clip((8414*r + 16519*g + 3208*b + 540928) >> 15)`, zero mismatches.
      The coefficients are exactly the limited-range BT.601 set that utils.c
      builds, so this is swscale's arithmetic rather than a curve fit to it.
      A shader can reproduce that with no ambiguity.

      **Chroma is the whole remaining problem, and it is not a box average.**
      A single red pixel moves a SIGNED 2x2 footprint in the chroma plane
      (deltas -2, +7 / -7, +21 against a gray baseline), and that footprint is
      not separable: an outer-product factorisation requires -49 == -42. So
      the chroma axis is a phased, multi-tap filter in 15-bit fixed point with
      a dither add, which is exactly the part a shader cannot approximate
      without changing bytes.

      **SUPERSEDED 2026-09-27 — the whole 6-tap downscale model below does not
      apply to the exporter, and the reason is a bug in the probe that had been
      feeding every one of these measurements.** Two separate errors, both
      worth keeping because either one alone produces confident nonsense:

      1. **NV12's chroma plane is byte-interleaved `U,V,U,V,...`, not
         `[U row][V row]`.** The probe printed "U" by walking offset 0,1,2,3
         and "V" from offset `uv_w`, so it was alternating U and V in the U
         label and reading misaligned in the V label. This is what produced
         the phantom "asymmetric 2x2 kernel" with deltas -7,+21,-2,+7 --
         MIXED SIGNS on a plane where a red impulse can only push U one way.
         Mixed signs are impossible for any positive-weight average, and that
         impossibility was the tell. It was not read as a tell; it was read as
         a swscale quirk. The layout is now established by content (a solid
         red frame reads 90,240 per pair, green 54,34, blue 240,110), which
         is the only way it could have been established.
      2. **The exporter's conversion is 1:1, so `initFilter` takes its
         unscaled branch and there is no `size_factor` filter to fit at all.**
         `render.odin:1216` is `sws.getContext(w, h, RGBA, w, h, NV12,
         BILINEAR)` -- same width and height. `chrSrcW == chrDstW`, so
         `filterSize == 1` and the `size_factor == 2` general branch below is
         dead code for this pipeline. The `hrow` fixture was a 2:1 downscale,
         i.e. a geometry the exporter never runs, and every tap count derived
         from it described that fiction.

      **The kernel that actually ships, measured 2026-09-27.** Impulse
      response over the whole plane, not a fitted row: a single red luma pixel
      at `(y, x)` moves exactly ONE chroma column `x>>1`, and exactly TWO
      chroma rows -- `y>>1` by -7 and the adjacent row by -2 (up when `y` is
      even, down when odd), touching nothing else. `x=8` and `x=9` give
      identical results and no other column moves, so the horizontal weights
      are equal. Solving against a solid red frame, which pins the weights to
      sum to 1, gives:

      ```
      horizontal  [1, 1] / 2      over luma cols 2C,   2C+1
      vertical    [2, 7, 7, 2] / 18  over luma rows 2K-1, 2K, 2K+1, 2K+2
      ```

      A separable 2x4 bilinear trapezoid. It checks out to the byte: A=7/18
      and B=1/9 imply a per-column delta of -18 for the impulse, and
      B*(-18) is exactly the observed -2. This is a shader in a handful of
      lines, and it is the thing to port -- not the 4-tap model, not the
      6-tap model.

      **The tap-fitting approach was the wrong instrument, and the reason is
      worth recording so nobody picks it up again.** `/tmp/opencode/fith.py`
      fits 4 taps x 2 phases against one row of output chroma
      (`hrow.txt`, 64 samples) and returns `[0.0, 0.0]` for all four phases.
      The rank deficiency is not noise in the data -- the probe's column
      pattern is a full-period LCG and every row is copied from row 0, so the
      vertical stage does collapse to a DC gain and a 1D fit is legitimate in
      principle. The model is wrong: swscale never builds a 4-tap chroma
      filter here. The exporter's context is `SWS_BILINEAR`, and in
      `initFilter` the 2-tap "bilinear" branch is gated on
      `xInc <= 1<<16 && scaler == SWS_AREA` or `scaler == SWS_FAST_BILINEAR`
      -- a 2:1 downscale with `SWS_BILINEAR` falls through to the general
      branch, where `scale_algorithms[SWS_BILINEAR].size_factor == 2` gives
      `filterSize = 1 + (2*chrSrcW + chrDstW - 1) / chrDstW`, which is ~6 at
      2:1, not 4. So the fit was solving for a filter that does not exist.

      The exact kernel, now read off the source rather than inferred:

      ```
      fone    = 1LL << (54 - FFMIN(av_log2(chrSrcW/chrDstW), 8))
      d       = FFABS((xx << 17) - xDstInSrc) << 13
                (times dstW/srcW when xInc > 1<<16, i.e. downscaling)
      coeff   = ((1 << 30) - d), clamped at 0, times (fone >> 30)
      xx      = (xDstInSrc - (filterSize - 2) * (1 << 16)) / (1 << 17)
      xDstInSrc += 2 * xInc   per output sample
      ```

      A symmetric triangular kernel over `filterSize` taps, in 54-bit fixed
      point, on a position grid that steps by half a source pixel. This is
      fully determined -- nothing here is left to reverse-engineer empirically.
      What remains is transcription, not discovery: `filterPos`, the
      `filter2` src/dst-filter pass, the normaliser, `input.c`'s two-pixel
      chroma siting, `hscale.c`'s rounding, and `output.c`'s dither+shift.
      Do that by porting those procs, not by fitting output bytes to a guessed
      tap count.

      Also settled along the way, because it invalidated a first measurement
      that looked like a broken pipeline: swscale builds chroma at
      `chrSrcW = w/2` (utils.c `initFilter`), so the chroma plane only reads
      the LEFT HALF of the source. A horizontal impulse at `x = w/2` is
      outside its support and correctly does nothing; at `x = w/4` it moves
      two chroma columns.

      **MEASURED 2026-09-27: the "just do the canvas instead" alternative is
      NET NEGATIVE on its own, and this reverses the earlier note here that
      called the two work items "additive rather than competing".** The canvas
      was decomposed with new `VYPER_FRAME_TIME` counters
      (`comp_zero_ns`/`comp_blit_ns`, and `res_upload_ns`/`res_gpu_ns`/
      `res_download_ns` inside the resample round trip) on the same 1920x1080
      fixture at 0.5x, one keyed clip plus a subtitle:

      | composite sub-stage | ms/f |
      |---|---|
      | canvas zero (8 MB `mem.zero`) | 0.45 |
      | visual walk (one span, all clips) | 5.05 |
      | &nbsp;&nbsp;- resample round trip (total) | 2.99 |
      | &nbsp;&nbsp;&nbsp;&nbsp;- stage upload (8 MB CPU->GPU) | 0.94 |
      | &nbsp;&nbsp;&nbsp;&nbsp;- resample pass + submit + wait | 1.12 |
      | &nbsp;&nbsp;&nbsp;&nbsp;- download + map + memcpy back (2 MB) | 0.92 |
      | &nbsp;&nbsp;- everything else in the walk (blits, subtitle) | 2.06 |

      The walk is timed as ONE span from before the loop to after it, not
      accumulated per case. A per-case accumulator placed before a clip's own
      work cannot contain that work, so the first attempt at this split
      subtracted the resample from a total that excluded it and printed a
      negative "blits"; the one-span form is what makes the containment true.

      Three consequences, and the third is the one that matters:

      1. The readback the canvas work removes is only **0.92 ms/f**, not the
         ~3 ms/f the round trip appears to cost. Attacking the round trip as
         a unit overstates the win by 3x.
      2. The non-resample `2.06 ms/f` of the walk is NOT mostly clip copying.
         `render_blit_region` is a plain row-wise `copy` (no blending), so the
         2 MB keyed blit is a small part of it and the subtitle rasterization
         is the rest. A GPU canvas would not remove that.
      3. A GPU canvas makes the download **larger**, not smaller. Today the
         readback is the clip's own rect (960x540 = 2 MB at 0.5x). Compositing
         into a GPU canvas means downloading the whole 1920x1080 (8 MB) once
         instead -- ~+1 ms/f of transfer -- to save a ~0.2 ms/f memcpy. For
         this single-clip case that is a clear loss, and it only breaks even
         when many keyed clips each pay a separate readback today.

      **So the two are COUPLED, not additive: route A is the prerequisite, not
      a parallel alternative.** The coupling is the real finding. `sws` is
      5.29 ms/f and it reads the 8 MB canvas on the CPU, so:

      - GPU RGBA->NV12 alone kills the 5.29 ms/f and changes nothing about the
        transfers -- the canvas is still downloaded to the CPU either way,
        because the encoder's input is a CPU buffer.
      - GPU canvas alone, per the table above, is net negative.
      - GPU canvas **and** GPU RGBA->NV12 together are the only combination
        that removes BOTH the 5.29 ms/f and the 1.94 ms/f of PCIe transfer,
        because then the canvas download feeds the conversion directly and the
        CPU never materializes 8 MB of RGBA at all.

      That ordering is worth more than either item alone, and it is why the
      chroma port is the blocker rather than merely the bigger item. It also
      means the remaining ~1.9 ms/f of upload/download is the price of a
      CPU-decoded stage, not a resample problem: it is only removable by
      keeping frames on the GPU end to end, which is the interop question
      (Active 1 / S1c) that the SDL `VkDevice` limitation gates.

      **NEW ANOMALY, measured in-app, not yet explained: on this fixture the GPU
      resample path is SLOWER than the CPU kernel it replaced.** Same command,
      same frames, only `VYPER_KEYED_GPU` flipped, 0.5x:

      | composite | GPU resample | CPU kernel |
      |---|---|---|
      | total | 5.50 ms/f | 3.05 ms/f |
      | canvas zero | 0.45 | 0.38 |
      | visual walk | 5.05 | 2.66 |
      | resample round trip | 2.99 | (n/a) |
      | keyed frames / gpu frames / fallbacks | 90 / 90 / 0 | 90 / 0 / 0 |

      The GPU round trip (2.99 ms/f) costs more than the ENTIRE CPU visual
      walk (2.66 ms/f), so on this fixture `VYPER_KEYED_GPU=1` is a
      pessimization of the export composite, not the win `gpu_probe` reports.
      This does NOT contradict `gpu_probe` (which measures the kernel in
      isolation, back to back, with no decode thread running) -- it is exactly
      the case that isolation hides:

      - `gpu_probe` in isolation: 1600x900->800x450 GPU 1.35 ms vs CPU 11.05 ms.
      - In-app, same class of resample with a real decoded stage and the
        producer thread running concurrently: GPU 2.99 ms vs a CPU walk of
        2.66 ms total.
      - `WaitForGPUIdle` is a full pipeline stall every frame, and the isolated
        probe amortises it over `ITERS`; in-app it is once per frame next to a
        memory-bandwidth-hungry decode thread. Which of those dominates is not
        yet established.

      So the honest state is: **the resample is NOT established as a win in the
      shipping configuration**, and the 8-10x in the probe is optimistic. This
      does not make the GPU path wrong -- the CPU kernel's 50x pathological
      case is real and does not reproduce here, which is why both numbers
      exist -- but "GPU resample is 8x faster" is a probe claim, not a
      shipping claim, and any future decision that leans on the 8x is leaning
      on the wrong number.

      **RESOLVED 2026-09-27: the probe's CPU column is the broken number, and it
      is wrong by ~10x, not merely optimistic.** Added the exporter's own
      geometry as a probe case (1920x1080->960x540, full stage, exactly what the
      exporter resamples) and it reads 15.7 ms in the probe against 1.3-1.5
      ms/call in the exporter. Same `yuv.rgba_resample`, same package, same
      geometry, and the exporter does 90 such calls per run at a constant
      full-stage crop (verified: crop width 1920..1920, area 2073600 on all 90).
      Everything that could explain it was tested and eliminated:

      - **Not the thread.** Ran the identical loop on a spawned worker thread:
        15.47 ms, matching main's 15.47 ms. The exporter's 1.45 ms is also a
        worker thread, so "the exporter runs it on a better thread" is out.
      - **Not warm-up or first touch.** Two back-to-back timed passes agreed to
        within 1% (15.75 vs 16.84, and 11.09 vs 11.21). An 8-iteration average
        cannot be hiding a ~115 ms one-time cost.
      - **Not loop order / driver contention.** Moved the CPU timing to run
        BEFORE the GPU timing: 10.98 ms against 11.05 ms before the move.
      - **Not the data.** `rgba_box_downscale` branches only on geometry
        (`span`/`rows` from 16.16 stepping), never on pixel values, so the
        fixture pattern cannot change its cost.
      - **Not the geometry.** All 90 exporter calls use the identical
        full-stage rect, and the dedicated probe case uses the same numbers.

      1.3-1.5 ms is also the physically plausible figure: ~2.07 M scalar
      channel loads plus 518 K stores is ~10 MB of traffic, which is ~1 ms of
      bandwidth. 15.7 ms works out to ~0.7 GB/s, which no memory subsystem on
      this machine sustains. **The exporter's number is the credible one and the
      probe's CPU column is measuring something other than the kernel.** The
      mechanism is still unresolved, so the probe's timing columns and its
      `N.NNx` ratio are now annotated in place as not-to-be-used-for-decisions;
      its correctness columns (mean/peak vs the CPU kernel) are unaffected and
      are what the gate actually asserts.

      **RESOLVED 2026-09-27, and the conclusion above was WRONG. There is no
      shipped regression; the probe was right and my measurement was the broken
      side.** Chasing the "10x" led to the actual defect, which was in how I was
      reading the number rather than in either code path.

      `rgba_resample` has three branches whose costs differ by more than an
      order of magnitude: 1:1 is `rgba_copy_rows` (a memcpy), a downscale is
      `rgba_box_downscale`, an upscale is bilinear. A keyed scale animation
      produces all of them across one run, and **I averaged them together.** On
      the keyed_export fixture at 0.5x, 89 of 90 frames are 1:1 and exactly ONE
      is a real downscale:

      | per geometry, in-app | CPU kernel | GPU round trip | |
      |---|---|---|---|
      | 1:1 (89 of 90 frames) | **1.21 ms** | 2.51 ms | GPU 2.1x slower |
      | downscale 1920x1080->960x540 (1 frame) | 15.34 ms | **5.71 ms** | GPU 2.7x faster |

      So the pooled "CPU 1.39 ms/call vs GPU 3.06 ms/call" that made the GPU path
      look like a pessimization was `(89 x 1.21 + 1 x 15.34) / 90` on one side
      and a full round trip on every frame on the other. The probe's 10.5 ms for
      a downscale and the exporter's 15.34 ms for one agree once you account for
      the 1.44x pixel difference. **The probe's ratio column was correct the
      whole time** and the annotation saying otherwise has been reverted.

      The real defect this exposed is one of REPORTING, and it had been hiding a
      genuine inefficiency: **the GPU path was running its full 8 MB upload +
      pass + 8 MB download on the 89 frames that needed no resample at all**,
      paying 2.51 ms to produce what a straight copy produces in 1.21 ms. Fixed
      by short-circuiting 1:1 before either resampler, straight to the existing
      fixed-scale blit (one copy from the decoded stage to the canvas, instead
      of copy-to-`kres_scratch` then copy-from-it). Measured on the same
      fixture, composite per frame:

      | composite | before | after |
      |---|---|---|
      | GPU arm (default) | 5.50 ms/f | **2.26 ms/f** |
      | CPU arm (`VYPER_KEYED_GPU=0`) | 2.66 ms/f walk | 2.90 ms/f walk |

      `keyed_export` is byte-identical across the change (1.0x `inf`, 0.5x
      58.707992), as it must be: the 1:1 GPU resample was already gated exact
      (gpu_probe 1600x900->1600x900 mean=0.00 peak=0) and `rgba_resample` takes
      its copy branch when dst == src, so this removes a resample, not a
      resample plus a conversion.

      **The 0.24 ms/f regression on the CPU arm is real and recorded rather than
      waved off.** It is a cache effect, not extra work: the old path wrote
      `kres_scratch` and then read it back hot, while the direct blit reads the
      decoder's stage cold on another core. Kept anyway, because the default GPU
      arm gains 3.24 ms/f from the same change and the fallback only runs when
      the GPU path is unavailable or explicitly pinned -- but if the CPU arm
      ever becomes the default, re-measure this before assuming the one-copy
      version still wins.

      Lesson worth keeping, because it is the same mistake twice: **a mean over
      mixed geometries describes no frame that was ever rendered.** Both the
      probe and the exporter now report per-geometry counts alongside the mean.
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

**Status: COMPLETE as of 2026-09-27** (Step E closed the last duplicated rule;
the two remaining "open" items were not duplication — see Step E). The goal was
to remove the duplicated preview/export machinery and fix the bugs that
duplication already caused. What is deliberately still NOT done is unifying the
two *pipelines* into a zero-copy path: that needs an interop spike (Active 1 /
S1c) and is its own project. Sharing the RULES is finished; sharing the
pipeline is not, and the two should not be conflated.

All three parity bugs are fixed (A1/A2 for the filter, B/B2 for geometry, C for
layering, D for subtitles) and `all` is green.

**Step E — DONE 2026-09-27: the last duplicated rule is now stated once, and
the two remaining "still open" items turned out not to be duplication at all.**

The section previously listed three things as still open. Checked against the
tree rather than against these notes, two of them dissolve:

- *"decode/stage sizing duplication"* — already shared. `source_fit_in_buffer`
  (decode.odin:1036) is the single implementation and both the preview slot
  path and the export stage path call it; `open_clip_decoder_ex` is the one
  stage-sizing entry point. Nothing to merge.
- *"preview/export text rasterization"* — not duplication but a correct
  producer/consumer split, and the code says so. The preview's FIRST pass
  rasterizes at the base font (48px) to produce the scale-independent
  `clip.source_w/h`; the export's snapshot CONSUMES those dims and only
  rasterizes at `48*scale` for resolution (preview_state.odin:533-549 spells
  out why the two notions are decoupled — baking the scale into `source_w/h`
  would make handle-drag double-count). Collapsing these into one proc would
  destroy the thing that makes the drag math work.
- *"the preview's UV arithmetic is not merged with the export's"* — still
  deliberate, and now stated as a boundary rather than an omission. The
  preview samples a fractional UV quad into a `PREVIEW_W x PREVIEW_H` buffer;
  the export blits integer pixels out of the max-scale decode stage. Different
  output spaces, so the backends stay separate. Only the ORDER is shared.

What genuinely remained was the draw-order rule, which was stated twice: the
preview sorted by `preview_draw_key`, the export relied on the order
`render_job.visuals` happened to be built in plus a trailing subtitle pass.
Both were correct, and correct by coincidence — nothing tied them together, so
the next layer rule would have been written twice and trusted twice. That is
the same failure mode that produced all three shipped bugs above.

`render_order.odin` now owns the rule: `SUBTITLE_PIN_KEY` and `draw_key(layer,
is_subtitle)`, with the meaning of the numbers and the reason subtitles pin
above everything written down once. `preview_draw_key` is a two-line adapter
onto a `Preview_Slot`; the export's subtitle pass names `SUBTITLE_PIN_KEY` as
the reason it runs last. The paint loops are deliberately NOT merged — one
function spanning a CPU blit and a GPU quad draw is worse than a rule called
twice, and the backends differ in more than the order.

**Also done: `subtitle_probe` is a gate now.** It was reachable only by setting
`VYPER_SUB_RENDER_PROBE` by hand, so nothing ran it — and nothing else in the
gate list covered it: `keyed_ab` and `zorder` use a source with no subtitle
clip at all, and the ui probe only checks the PREVIEW's order ("preview order
ok (track order, subtitles pinned on top)"), never the export's. First version
of the target was a false green — it passed on process exit 0 while the binary
bailed during startup having asserted nothing, and it also inherited
`$PROBE_ENV`, whose `VYPER_UI_PROBE` runs the ui probe first and needs a media
file the target does not have. It now runs standalone and greps for the probe's
own completion line, so "the probe did not run" is a failure.

Remaining in this section: nothing. Unifying the two *pipelines* (no CPU RGBA
round trip) is still Active 1 / S1c and is still deferred — but that is a
different project from sharing the rules, and conflating the two is what left
this section looking unfinished.

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

**Step B4 — DONE: the text buffers' grow policy, which was copy-pasted six
times.** The raster core was already shared (`rasterize_title_into_buffer` /
`rasterize_lines_into_buffer`), so what remained was the BUFFER POLICY around
it: "if this byte slice is smaller than N, free it and make a bigger one". That
grow-only check appeared six times -- twice in the export worker, four times in
the preview slot (the title base re-measure, the title bake, the subtitle base
measure, the subtitle bake) -- each spelling it out again and each recomputing
the size TWICE, once in the comparison and once in the `make`.

Two of the six carried a comment worth keeping: `slot.text_base_buf = {} //
NOTE: delete leaves a stale non-zero len; a later grow-check must not see it`.
That is CORRECT, and checking it against the runtime was worth doing
(AGENTS.md 11): Odin's `delete_slice` only calls `mem_free_with_size` and
leaves the slice HEADER alone, so afterwards the slice still reports the old
length and a dangling pointer. It is a real gotcha, and the zeroing was
treating the symptom.

`text_buf_ensure` is now the one policy, and the stale-header hazard is
documented where it is now handled rather than at each site: the check happens
BEFORE the delete and the return reads the freshly assigned header, so there is
no window for a stale length to be seen and the `= {}` is unnecessary. The
buffer still differs per owner (the worker's `setup_scratch` vs each preview
slot's own `text_scratch` -- the UI thread and the worker must not share one, it
would be a data race) while the policy is shared, which is the actual shape of
the duplication: same code, different owner, not something a blanket "share the
buffer" refactor could have collapsed.

Renaming the locals at the two subtitle sites (`baked_scratch` / `baked_buf`
versus the base-measurement pair) is not cosmetic: the same two buffers are
asked for two different sizes in one scope, base font and 48*scale, and the
shadowing that produced was the compiler correctly reporting that they are
different things.

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

**Step F — DONE 2026-09-27: the clip visibility predicate, which was the one
duplicated RULE Active 10 had not caught.** Step E closed the layering rule;
the predicate every pipeline uses to decide "is this clip on screen at frame
F" was still written out longhand in ELEVEN places across nine files
(`proxy.odin`, `render.odin` x5, `preview_state.odin` x2, `flash_rec.odin` x2,
`timeline.odin` x2, `main.odin`, `audio.odin`). It had already drifted, which is
the outcome AGENTS.md 2 predicts for copy-paste-and-tweak: `main.odin` used `>`
where the other ten used `>=`, so the auto-keyframe gate accepted the playhead
one frame PAST the clip end, and no gate caught it.

  - `clip_visible_at(frame, start, length)` now states it once, half-open on
    `[start, start+length)`. Three `i64` rather than a `Clip` parameter, because
    the same test applies to sources the timeline does not own (`Render_Video_Src`,
    `Render_Text_Src`, subtitle clips); a proc over `Clip` would have left the
    non-`Clip` sites inlining the arithmetic, i.e. the duplication again.
  - The off-by-one is gone as a side effect — that was the point.
  - `timeline_probe.odin` pins the boundary: one frame before start, at start,
    at the last frame, AT THE END (must not be visible), and a zero-length clip
    (must never be visible, or a clip left by splitting at frame 0 would show
    for exactly one frame while every other case still passed). Verified the
    probe FAILS when the bound is flipped back to `>`, so it is a real pin and
    not decoration.
  - `timeline_probe` was, like `transform_probe` before it, reachable only by
    setting `VYPER_TL_PROBE` by hand — no gate ran it, so the new assertion
    would have been dead. It is now a gate target and a member of `all`.

Not duplication, deliberately left alone: the two paint loops stay separate
(one rasterises CPU pixels out of decode, the other draws a fractional UV quad
on the GPU), and `flash_rec.odin:173`'s `b.start == a.start + a.length` is an
adjacency test, not a visibility one. The remaining large unification —
collapsing export's CPU raster -> readback -> swscale into the GPU pipeline —
is S1c, not a refactor, and is tracked there.

**Evidence (behavior-preserving):** full `all` green, including `valgrind` and
`render_valgrind` at 0 definitely / 0 indirectly lost.

## Active 11 — Unified render engine: one evaluation, multiple sinks, minimal state

**Status: S1 + S2(audio) + S3(geometry/opacity) + reduced S4 + S5 landed
2026-10-02; S6 deferred by decision.** Branch `render-engine` (base `639d20a`),
merged into `main`. **The work-stream stops here** — S6 (incremental export) is
not being built now, and the state below is what the next session inherits.

**What is done, in one paragraph.** Preview and export no longer keep their own
copy of a derived fact: audio gain has one committed home (`Audio_Geom_Slot` →
`Audio_Gain_Snapshot`, read by both sinks), and clip geometry/opacity has one
evaluator (`Geom_Sample`) sampled by both. The two per-thread latches that remain
are load-bearing for the ownership swap, and both carry the *shared shape* and
call the *shared evaluator*, so there is one meaning per fact. The export's
preview sink now shows the frame the export is actually producing, and the
document is locked while it does.

**Why.** Preview and export are two *drivers* over two *copies* of the same
derived facts, and every copied fact is a drift site. The keyed-gain bug shipped
this month is the proof: the fact "clip gain" lived in `clip.gain` (canonical),
`Audio_Geom_Chip.gain_dB` (playback copy) and was supposed to live in
`Render_Audio_Src` (export copy) — the export copy was never wired, so rendered
files ignored the slider and its automation. Active 10 shared the *rules* between
preview and export and explicitly left the *pipelines* separate (`TODO.md:2310`,
deferred as S1c because a zero-copy *visual* pipeline needs GPU interop). That
deferral conflated two separable things — sharing the **evaluation** vs sharing
the **buffer** — and audio, which needs no interop at all, was swept along and
left as two whole parallel systems. This work-stream shares the system and the
data source. Guiding principle (user, 2026-10-01): **"Multiple state is the
devil's home — reduce state as much as possible."**

**Findings (verified against the tree, not from memory).**

Two *audio* systems today:

| | playback (audio preview) | export |
|---|---|---|
| snapshot | `audio_geometry_commit` → `Audio_Geom_Slot` chip (gain as `Audio_Gain_Snapshot`) | `render_audio_src_from_chip` reads the **same** slab chip → `Render_Audio_Src` (S1: no longer re-derived from the live clip) |
| provision | `audio_provision` (`audio.odin:907`) → `Play_Src`/`Play_Seg` | `render_audio_open` (`render.odin:1810`) |
| decode | `audio_src_pull` / `audio_src_seek_anchor` | `render_audio_pull` (a reimplementation; it even dropped the seek preroll) |
| mix | `audio_mix_frame` (`audio.odin:1130`) | inline loop (`render.odin:2957`) |
| grouping | one decoder per *source stream* (`audio_provision_find_group`) | one decoder per *clip* (re-opens the same file per split) |

`audio_mix_frame`'s own comment says it is "exactly like the render loop
(render.odin render_worker_run)" — the author knew it was a copy.

Two *video evaluation* drivers:

| | preview | export |
|---|---|---|
| driver | `update_preview_slots` (`frame.odin:35`) | `render_worker_run` (`render.odin:2155`) |
| geometry/opacity sample | `kf_geom_sample_lane` (`preview_state.odin:502,509`) | `render_eval_keyed_geom` / `render_kf_geom_rect` |
| source | `proxy_pick_for_frame` (`preview_state.odin:700`), fallback original | original `clip.path` (`render.odin:1001`) |
| resolution | `PREVIEW_W×PREVIEW_H` | per-clip max-scale stage |
| output | GPU texture → widget | GPU canvas → NV12 → encoder |

Duplicated-*derived* state (all pure functions of the document + frame):

- evaluated geometry/opacity: `Preview_Slot` **and** `Render_Video_Src.{transform_*,crop_*,scale,opacity,kf_geom}`.
- gain + gain keys: `Audio_Geom_Chip` **and** `Play_Seg` **and** (was) `Render_Audio_Src`.
- draw order: preview's `preview_draw_key` call sites **and** the order of
  `Render_Job.visuals` (Active 10 collapsed the *rule* into `render_order.odin`
  but each side still materializes its own ordering).

Already in our favor (do not rebuild): proxy-vs-original is *already* a per-call
source policy (`proxy_pick_for_frame`), and preview vs export already composite
through shared shaders (`quad.vert`, `blit_box.frag`, `Quad_Uniforms`). What is
missing is the single driver, not the GPU half.

Absent entirely: a live (locked) preview of frames as they render
(`render_progress` is a text counter; the preview keeps showing the timeline), and
any export chunk cache for incremental re-export.

**Model (target).**

- **Canonical document** — `timeline` + `project`. One source of truth. The gain
  bug cannot exist when a fact has one home.
- **Evaluation is a pure function**, never a stored value: a proc over
  `(document, frame, resolution, source_policy)` returning what the sink needs.
  No intermediate "plan" object — a plan is derived state, i.e. the thing we are
  removing.
- **Sinks** = preview display, export encoder, audio device, audio encoder. A
  sink holds only runtime resources (decoders, GPU textures, rings, encoder) —
  distinct objects, not copies of a fact.
- **Cross-thread handoff is a committed version + generation, not a deep copy of
  derived facts.** This is the seam AGENTS §1 already names ("the commit bumps a
  generation, and caches keyed on it drop stale entries free"); `kf_structure_gen`
  and `gain_epoch` are its existing instances. The worker reads the immutable
  committed document; architecture-specific snapshots (`Render_Job`,
  `Audio_Geom_Slot` chip copies) collapse onto it.

**Consequence for the active asks** (why this is the right foundation, not a
detour):

- Single engine = the pure evaluators with one input, the committed document.
- Live preview during render = the worker already composites into
  `Render_Enc_Slot.canvas` (`render.odin:1848`); the preview sink displays that
  buffer and the input gate freezes. Zero new state.
- Incremental export = a chunk keyed by `(document generation, frame range,
  source policy)`. Only possible once evaluation is deterministic from one
  document — the same property removing the copies buys.

**Steps** (each lands + probe + vet before the next; expect probe-first, and
mutation-test every new assertion):

- [x] **S1 — Define the committed-version read model.** Landed 2026-10-01.
      Named the cross-thread readers (playback producer ← `Audio_Geom_Slot`
      double-buffered slab + `gain_epoch`; render worker ← `render_job` deep
      copy built in `render_start`; `vdecode` ← per-request descriptor;
      `import_bg` ← a path, no timeline). **Key finding: the per-sink copies
      (`Play_Seg`, `Audio_Geom_Chip`, `Render_Audio_Src`) are load-bearing** —
      each thread latches a stable view across the double-buffer swap / render
      lifetime, so the copies cannot simply be deleted; what must be shared is
      the *definition*, the *derivation*, and the *evaluator*, not the physical
      storage. That coupling merged the audio half of S2 into S1.
- [x] **S2 (audio) — Collapse the audio copies.** Landed with S1. New committed
      shape `Audio_Gain_Snapshot {db, keys[GAIN_KF_MAX_KEYS], n}` (`audio.odin`),
      built only by `audio_gain_snapshot_from_clip` and evaluated only by
      `audio_gain_linear` (wrapping `kf_gain_linear`, which stays the shared
      evaluator). `Audio_Geom_Chip`, `Play_Seg` and `Render_Audio_Src` all embed
      it; the dead `Play_Seg.gain` (linear, written but never read) and the
      parallel `gain_dB`/`kf_keys`/`kf_n` fields are gone. `audio_gain_fold`
      copies only `db` (the keyed curve is unchanged by a gain-knob drag). The
      export no longer re-derives gain from the live clip: `render_start` calls
      `audio_geometry_commit()` and builds every `Render_Audio_Src` from the
      active slab via `render_audio_src_from_chip`, so **export and playback
      read the same committed source**. Probe (`keyframe_probe`): snapshot
      evaluates like `kf_gain_linear` at a key and a midpoint; playback seam ==
      export seam; commit captures static dB + track; `render_audio_src_from_chip`
      copies the chip's gain + identity verbatim. Gates: check/build/probe/
      `VYPER_KEYFRAME_PROBE`/geom_key_probe/transform_probe/timeline_probe/
      keyed_export/valgrind/geom_key_valgrind/undo_valgrind all green.
      **Consequence (accept + watch):** the export now inherits the committed
      slab's bounds — `AUDIO_GEOM_MAX_CLIPS :: 4096` clips and
      `AUDIO_GEOM_PATH_ARENA :: 1<<20` path bytes per slot (previously export
      used uncapped dynamic arrays). Past the cap the commit logs once and mutes
      the overflow clips for **both** playback and export; this is now a single
      ceiling instead of two disagreeing ones. Export source order is slab
      (track/clip) order.
- [x] **S2 (video) / S3 — One video-frame evaluator (geometry + opacity).**
      Landed 2026-10-01. `Geom_Sample` (indexed by `Render_Geom_Prop`, so a
      property added to the enum is present with no second list) is the single
      evaluated shape. `geom_sample_clip` is THE live evaluator (preview calls
      it; `preview_state.odin` no longer hand-lists the eight lane names), and
      `geom_sample_flat` is its frozen counterpart that `render_kf_geom_rect`
      now samples through — so the export's per-frame values come from the same
      enum-driven loop, not eight hand-inlined `kf_sample_keys` calls. Both read
      the same resting base (`geom_resting_value`). The per-thread latches
      (`Preview_Slot` fields, `Render_Video_Src` resting fields) stay and are
      load-bearing, exactly as S1 found for audio. Probe (`render_kf_probe`
      case G): live vs flat agree on EVERY lane at four offsets, for a clip
      keying every lane including a PACKED crop section; mutation-tested by
      dropping a lane from the flat sampler (fails). Gates green.
      **Remaining in S3:** source policy (proxy vs original) is already a
      per-call policy (`proxy_pick_for_frame`), not a duplication; draw order
      was collapsed by Active 10's `render_order.odin`. The residual is the
      *pipeline* (GPU quad uniforms vs CPU rect), which is the S1c interop
      boundary, not a duplicated fact.
- [x] **S4 — Sink split (reduced; the storage half was the wrong target).**
      Landed 2026-10-01. S1's latch finding makes the *storage* half of the
      original step impossible, not merely inconvenient: `Preview_Slot` latches
      the sampled geometry across the frame because the draw pass runs after
      `update_preview_slots` and the live clip may have been edited since, and
      `Render_Video_Src.geom_base` exists because the worker may never read a
      live `Clip`. Deleting either is a correctness regression, not a state
      reduction. What remained reducible was the latch *SHAPE* and the
      hand-copied property lists around it, and that is done:
      - `Preview_Slot` carries one `geom: Geom_Sample` instead of eight named
        f32s; `update_preview_slots` is `slot.geom = geom_sample_clip(clip,
        frame)` — no property list at all — and the text paths clear crop via
        `geom_clear_crop`. A `Render_Geom_Prop` added to the enum now needs no
        edit in the preview state or the draw path.
      - `Render_Video_Src` carries `geom_base: Geom_Sample` (filled once at
        `render_start` by the new `geom_sample_resting`) instead of eight
        resting fields, and `render_kf_geom_rect` takes that base as one
        argument instead of eight named floats (10 probe call sites updated).
      - `gpu_draw` no longer rebuilds a throwaway `Clip` from the slot latch
        just to call `clip_image_bounds`; the new `clip_image_bounds_geom`
        takes evaluated geometry, and `clip_image_bounds` is the thin
        `clip_geom_get` wrapper the editor's border/handles/hit-test keep using.
      **Bug found and fixed by the collapse.** `Render_Video_Src.opacity` was
      both the resting base AND the per-frame alpha, so a keyed fade overwrote
      the base with the previous frame's sample: every frame past the last key
      blended at the last keyed value instead of the clip's own opacity, and
      re-rendering the same frame produced a different result. The resting value
      now lives in `geom_base[Opacity]` (immutable for the job) and `opacity`
      is only this frame's alpha, seeded from the base in the setup loop. Pinned
      by `render_kf_probe` case H, which drives the real
      `render_eval_keyed_geom` across a keyed frame and a post-key frame;
      mutation-tested by restoring the old read (fails). `render_kf_probe_check_near`
      now appends got/want/eps itself, so a failure line has no `%!(EXTRA)`.
      Gates green: check, build, probe, `VYPER_RENDER_KF_PROBE`,
      `VYPER_KEYFRAME_PROBE`, geom_key_probe, transform_probe, timeline_probe,
      keyed_export, valgrind, geom_key_valgrind, undo_valgrind.
- [x] **S5 — Live locked preview during render.** The preview sink displays the
      export worker's current composed frame, and editing/playhead input is gated
      while `render_is_busy()`.

      **Why a mailbox and not the encode slot.** `Render_Enc_Slot.canvas` is
      owned by the composite worker and refilled by the encoder, so reading it
      from the UI is a race with both. The live frame is published through
      `Render_Live` (`render.odin`): one session-heap RGBA buffer sized to the
      job canvas, allocated in `render_live_begin` on the UI thread BEFORE the
      worker starts (the job arena dies with the worker; this buffer must
      outlive it) and reused across runs at the same size. `ready` is the only
      shared word: the worker copies bytes, writes `frame`, then release-stores
      `ready`; `render_live_drain` acquire-loads, and the claim is **held for
      the whole copy out**. The first version cleared the flag before handing
      back a pointer, which let the composite refill the buffer mid-read — a
      torn frame, and one with no tell in the pixels.

      **Overflow policy: DROP.** If the UI has not drained, the composite skips
      publishing and keeps encoding; the UI keeps showing the older COMPLETE
      frame. The producer is never stalled by the consumer (AGENTS §1), which is
      the whole point — a progress view must never be what slows an export.

      **Rate: 100 ms** (`RENDER_LIVE_PUBLISH_NS`). The preview during an export
      is a progress display, not the 60 fps editing surface; publishing every
      composite frame would pay a full-canvas conversion for pixels nobody sees
      at that rate. The window runs from the last ACCEPTED publish, so a burst
      of skipped attempts does not push the next real frame out.

      **The GPU path is the one that matters.** With `gpu_nv12_enabled` (the
      default) the encoder consumes the packed NV12 canvas and `eslot.canvas`
      holds the ring slot's PREVIOUS frame, so publishing it would show a real
      but stale image. `render_live_publish` therefore takes whichever canvas is
      real and converts NV12→RGBA through one `sws.Context` per run.

      **The NV12 plane layout is a trap, and it cost a segfault.** NV12 is TWO
      planes — full-res luma, then byte-interleaved U,V at offset `w*h` with a
      row pitch of `w` — and swscale reads `srcSlice[1]` unconditionally. A
      one-element source array hands it whatever followed it on the stack. The
      layout is pinned by `render_live_probe` case 5 against the same swscale
      call, not a copy of the comment.

      **Gating is two seams, not every call site.** `interaction_post_build`
      skips the editing dispatch while busy (still running `interaction_release`,
      so a gesture started before the export commits and unwinds instead of
      sticking in `.Drag` forever), and `app_claims_key` refuses app shortcuts so
      playback/playhead keys cannot move the playhead out from under the render.
      The Cancel button and ESC stay live.

      Probe: `render_live_probe` (gates `render_live_probe` +
      `render_live_valgrind`) — pins that the drained frame is the frame that
      was published (bytes and timeline frame), the DROP policy, the usability
      gate, the publish interval, the end-of-run/reuse/teardown ownership, and
      the NV12 conversion. Four mutations fail it: drop→overwrite, gate removal,
      interval removal, chroma pitch `w`→`w/2`; a fifth (one source plane)
      fails by segfault, which is the crash the layout bug actually was.
      The end-to-end render test now stands in for the UI — it drains the
      mailbox in its wait loop and fails if nothing was published or if every
      published frame was black — so the publish path is exercised headlessly by
      `keyed_export` and `render_valgrind`, not only by the probe. Gates green:
      check, build, probe, `VYPER_RENDER_KF_PROBE`, `VYPER_KEYFRAME_PROBE`,
      geom_key_probe, render_live_probe, transform_probe, timeline_probe,
      keyed_export, yuv_exact, gpu_nv12, gpu_composite, opacity, gpu_probe,
      zorder, subtitle_probe, proxy_probe, smoke, valgrind, geom_key_valgrind,
      undo_valgrind, render_valgrind, render_live_valgrind.
- [ ] **S6 — Incremental (chunked) export. DEFERRED 2026-10-02, not started.**
      Chunk cache keyed by `(document generation, frame range, source policy)`;
      re-export only chunks whose key changed. The S1–S4 determinism it depends
      on has landed, so this is unblocked whenever it is wanted — but note what
      it will cost before picking it up: it needs a *document generation* counter
      that does not exist yet, and every mutator that can change a frame's output
      has to bump it. A cache key that misses a mutation returns stale video,
      which is worse than a slow export, so the generation counter is the whole
      design and cannot be sprinkled on later.

**Out of scope / dependencies.** The zero-copy GPU pipeline (Active 1 / S1c) is
orthogonal — this shares evaluation, not buffers, so it does not wait on GPU
interop. Active 1 already covers hw decode and "preview the original when the host
keeps up"; the source policy here builds on that rather than replacing it.

**Decision (settled in S1).** Extend the existing committed-slab pattern, not a
new persistent document. The committed source of truth for audio gain is the
`Audio_Geom_Slot` chip (via `Audio_Gain_Snapshot`); both sinks read it. Per-thread
latches stay (they are load-bearing for the swap), but they carry the shared shape
and share the evaluator, so a fact has one committed home and one meaning.

**Decision (settled in reduced S4).** Keep `Audio_Geom_Slot` as the committed
read model; the broader generation scheme is *not* being adopted, and that is
what S6 above is now waiting on. The video side did not want a double-buffer
committed view — it wants one immutable per-job snapshot instead, which is what
`Render_Video_Src.geom_base` is (taken once in the setup loop, read by the worker,
never re-derived from a live `Clip`). Two sinks, one snapshot discipline:
whatever a sink needs to stay consistent for the length of a run is captured when
the run starts, not recomputed from a document that can move under it.

**Why the stream stops here.** S1–S5 each removed duplicated *state*, which is
where the drift bugs came from. S6 would add a *cache*, which is the one thing
this work-stream has been arguing against: it introduces a second copy of a
derived fact that can disagree with the first, and the failure is a video file
that looks right. Not worth it until an incremental export is actually needed
rather than anticipated.

## Active 12 — OS file drag-and-drop: media bin + timeline

**Status: landed 2026-10-02.** Branch `file-dnd` (base `8c01a84`), merged into
`main`. `dnd_probe` + `dnd_valgrind` are members of `all`.

**The defect.** Dragging a file in from the desktop did nothing, on every
platform. Not a Wayland problem: `event.odin` is the app's only `sdl.PollEvent`
site and its switch handled six event types (`QUIT`, `WINDOW_CLOSE_REQUESTED`,
`KEY_UP`, `KEY_DOWN`, `TEXT_INPUT`, `MOUSE_WHEEL`). None of the five drop kinds
were routed, and nothing in the tree read them — the SDL3 binding exposes
`DROP_FILE`/`DROP_TEXT`/`DROP_BEGIN`/`DROP_COMPLETE`/`DROP_POSITION` and a
`DropEvent` union, all unused. So Windows and Linux failed identically, which is
what ruled out the Wayland theory; `TODO.md` had no DnD entry at all, so nothing
tracked the gap either. `mediabin.odin:349` even describes the bin drag ghost as
mirroring "OS file drag-and-drop" — the counterpart was intended and never built.

**Why it stayed invisible.** Ignoring events is not a crash. There was no path
that could fail, so no gate had anything to catch.

**What it does now.** `dnd.odin` owns the gesture:
- `DROP_BEGIN`/`POSITION`/`FILE`/`COMPLETE` are routed from the SDL switch;
  `DROP_TEXT` is routed too and deliberately dropped — a text selection dragged
  out of another app is not a path, and importing the clipboard as a file name
  would be worse than ignoring it.
- Drop on the **media bin** → imported to the bin only. Drop on the
  **timeline** → imported *and* placed on the hovered lane. Anywhere else →
  refused, silently (the pointer already shows where the user aimed; a notice per
  release would nag on every pass over dead space).
- "Decodable or readable" is one gate, `import_path_to_bin`, lifted out of
  `open_file_at` so the open-file flow and a drop cannot drift apart on what the
  bin will hold. `.srt` still lands in the bin only.
- The timeline drop runs the same two calls `end_media_drag` runs
  (`import_path_to_bin` then `add_asset_to_timeline` with
  `timeline_drop_target`/`timeline_frame_from_x`), which is what makes "dropped
  on the timeline" identical to "dragged out of the bin" by construction instead
  of by two paths agreeing today.
- The drop zone highlights while the drag is over the window (tint + border +
  "Drop to import"/"Drop to place"), re-resolved every frame because the target
  depends on layout as well as on the pointer.

**One honest limitation, and why it is not a gap.** No backend reveals a dragged
file's *name* before the release — X11, Wayland and Windows all report only "a
drag is over this window" until the drop. So the per-stream ghost lanes a bin
drag paints cannot exist here: at `DROP_BEGIN` the document does not know what is
coming. The highlight therefore shows the zone, and nothing more. This is why
`drop_zone_at` asks `timeline_drop_target` (the resolver the bin drag releases
through) rather than testing the timeline panel's box: the first version tested
the box and refused every drop on an *empty* timeline, because with no tracks
`TrackArea` is never laid out and the timeline body *is* `EmptyTimeline`. The
probe sweeps the window in both directions to keep that equivalence pinned.

**Probe.** `dnd_probe.odin` (VYPER_DND_PROBE) covers the decisions a drop makes
after delivery, since a probe cannot synthesise a cross-process drag: the box
arithmetic including a degenerate pre-layout box, the real laid-out panels (bin
centre imports, empty-timeline centre places, preview refuses), the
bin-drag/OS-drop equivalence swept across the window, the import gate refusing a
text file and a vanished path, and the BEGIN/POSITION/COMPLETE state (a
position must not survive into the next drag; COMPLETE must clear the whole
gesture). Mutation-checked: reverting the lane resolver to the panel box fails
331 assertions, dropping the `has_position` reset or the COMPLETE clear fails
three, and removing the import gate fails two.

**Memory.** Each dropped file hands an SDL-owned buffer to the bin, which clones
what it keeps — so `sdl.free` on the event buffer is the only owner that can
release it, and `dnd_valgrind` is the gate that measures that handoff (0
definitely lost, 0 indirectly lost, no invalid free).

## Active 16 — Export frame rate came from the first video source, not the frame grid

(Numbered after main's Active 13-15 rather than taking 13: this branch was based
on d279b45, before those landed, and two sections numbered 13 is exactly the drift
the rest of this file's naming rules exist to prevent.)

**Status: fixed 2026-10-03.** Branch `parity` (base `d279b45`). `parity` is a
member of `all`. Found while investigating why `baby.vyproj` exports 9.72 s of
video for a 20.25 s timeline.

**The defect.** The export worker derived its output rate from the first entry
of `render_job.videos`:

```
} else if len(render_job.videos) > 0 {
    rfps_num = render_job.videos[0].dec.fps_num
```

"How fast does this file play" is a different question from "what rate is the
frame grid defined on", and the two coincide only when the first visual source
is the one that set the grid. A still image is the case that breaks it: an image
demuxer reports an arbitrary `avg_frame_rate` (`25/1` for a PNG), so a project
whose first video clip was a still exported at 25 while its timeline played at
12. Every complaint follows from that single number — the file was retimed by
`25/12 = 2.08x`, so keyed values, positions and clip lengths all landed on
different output frames, and the duration was wrong by that factor. The old
comment claimed the fallback existed so the timeline grid would render 1:1 with
the sources, which is what made it look deliberate; it did the opposite, and
`media.odin:359` already excludes stills when SETTING the grid rate, so the
import side and the export side disagreed about what the grid is.

**The fix.** One resolver, one snapshot, no second opinion:
- `state.odin`: `project_rate_ok` (rejects zero, negative, NaN, Inf — a rate
  loaded from a project file is data that arrives broken, so it falls through
  rather than asserting) and `project_fps` (explicit project rate → the rate the
  first non-still import established → 60). `timeline_fps` is now
  `playback.magic_fps` → `project_fps`, so the DIAG playback override stays a
  preview-only knob and can never reach a container's time base.
- `state.odin`: `fps_rational` maps a rate to its exact container fraction,
  keeping the `1001` denominator for 23.976 / 29.97 / 59.94. Rounding 23.976 to
  `24/1` makes an export 0.1% long — a frame lost every ~40 seconds.
- `render.odin`: `Render_Job` carries `fps`/`fps_num`/`fps_den`, resolved once
  in `render_start` on the UI thread — before the snapshot walk, because the
  subtitle clips built by that walk copy the rate into their own struct. The
  worker reads the snapshot; the video mux, the 48 kHz audio bus and the subtitle
  timing all read the same three fields.

**Probe.** `parity_probe.odin`, gate `parity`, in two modes.
- `VYPER_PARITY_FIXTURE` builds a project that collides BY CONSTRUCTION: a still
  imported first (so it is `videos[0]`) and a 30 fps clip second (so the grid
  rate comes from the video). It ASSERTS the precondition that the still's own
  reported rate still differs from the grid's — a future ffmpeg that made image
  streams report a sane rate would otherwise leave the gate unable to detect the
  bug, passing for a reason that means nothing.
- `VYPER_PARITY_PROBE="<in.vyproj>|<out.mp4>"` runs the same checks against any
  real project. This is how `baby.vyproj` was verified: `12/1`, 243 frames,
  20.25 s, exit 0 (it was `25/1`, 9.72 s before).
- Three separate claims, because the first version of this probe checked only
  the geometry and passed a project that was broken in the rate: the rate the
  job carries, the rate the OUTPUT FILE carries, and the per-frame resolved pose
  across both evaluators. The middle one is not redundant: asserting the job
  struct proves only that `render_start` resolved something, and the restored
  pre-fix worker passed that assertion while muxing a different rate. Only the
  container can speak for what shipped.
- The resolver's own table is checked directly (7 rates mapped, 7 invalid inputs
  rejected), including the NTSC rationals, which no end-to-end path reaches and
  which a dropped branch would leave green.
- Mutation-checked. Restoring the source-derived chain fails with "is muxed at
  25/1 but the frame grid is 30"; breaking the NTSC branch fails with "rate
  23.976 became 24/1".

**Memory.** `parity_valgrind` is a member of `all`. The gate found two things
and the first version of this note was wrong about which:
- The probe's own `os.exit` skipped main's `defer sdl.Quit()`, while the export
  worker's `sdl.Init(VIDEO)` had run — 471 bytes definitely lost. The app itself
  always paired them; this was a probe-exit bug, and the fix is the probe's
  `parity_probe_exit` (GPU objects released first, then SDL down, as SDL
  requires).
- The GPU resampler singleton genuinely had no success-path teardown, and
  `gpu_resample_release` now provides one — but deleting that call moves the
  leak totals by ZERO bytes, so it is not what the number was measuring. It is
  kept because SDL's documented ordering requires it, not because it closes a
  leak; recorded here so nobody later reads the teardown as leak-fixed.
- 72 bytes in 1 block remain, from the `sdl.Init(VIDEO)` the export WORKER thread
  issues: SDL's per-thread video state is orphaned when that thread exits and no
  later release reaches it. One block per process. The gate asserts an invalid-
  access invariant (which caught the probe's own use-after-free), non-vacuity, a
  0/0 SDL Init+Quit control proving the exit teardown is complete, and a named
  bound on definitely-lost so any new leak fails. The control is executed by the
  gate rather than quoted: an earlier "SDL alone leaks 120 bytes" baseline was
  measured against a stale binary that never ran the control at all.

**Two probe bugs found while building it, both the ownership rules biting.**
The drain loop first returned a buffer its own `defer delete` had freed (a
use-after-free on every run), and it read the buffer after the final
`render_live_drain` returned false — reporting "the export is black" about a
frame nobody delivered, on a file with pictures in it. The probe also has to set
`render_live.shown` itself: `render_live_publish` refuses to publish until a
consumer has drawn, so a probe that only drains measures a mailbox nobody wrote
to. A probe that reports a measurement it did not take is worse than no probe.


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

## Implemented — per-gesture audio commits (scrub/drag re-provision storm, 2026-09-29)

- Symptom: scrubbing the ruler across a long video left audio dead for the
  rest of the session — hours of A/V skew, every producer telemetry counter
  frozen (`prov=1`, `rsync` climbing) while `d` diverged to -8895s.
- Root cause: `.Playhead_Scrub` called `audio_seek(frame)` per UI frame. A seek
  is not a playhead write — it clears the device and reopens every decoder
  (tens to hundreds of ms). A drag queued re-provisions faster than the
  producer could retire them, so it never reached the feed path and the device
  starved permanently after the drag ended.
- Fix: continuous gestures apply live but commit the audio engine once, on
  release, only if the gesture moved:
  - `.Playhead_Scrub` sets `playhead_scrub.moved` when the frame changes and
    calls `audio_seek(playhead.frame)` once in the release case; a
    click-without-drag commits nothing (`state.odin` `Playhead_Scrub_State`).
  - `.Clip_Move` dropped its per-frame `audio_note_edit()`; the release commits
    once via `audio_note_edit()` under the existing `moved` predicate.
  - `.Clip_Resize` dropped its per-frame `audio_note_edit()`; commits once on
    release via `audio_note_edit()` under `clip_resize.moved`.
  - Move/resize use `audio_note_edit` (not a bare `audio_seek`) because they
    change clip geometry, which must reach the producer's slab before it
    re-provisions; the scrub only moves the playhead, so it seeks directly.
- Diagnostic: the `[skew]` alert gained `age=%.1fs` (time since the producer
  last published `playback.dev_at_ns`). A wedged producer previously read as
  healthy because the HUD extrapolated its frozen counters forward; `age` climbs
  into the minutes when the producer thread is stuck. Saturates to 0 rather
  than underflowing when a publish lands between the two clock reads.
- Committed as `e69afb5` ("audio: commit scrub/drag re-provision once on
  release"); `./scripts/gate.sh check build probe smoke valgrind` pass
  (`smoke: ok (124)`, `ui-probe` all ok; valgrind 0 definitely/indirectly lost,
  no invalid access).


---

## Implemented — per-clip opacity / color modulation (2026-09-29)

- Model: `Clip.opacity` (`f32`, `0..1`, default `1.0`) as a resting value.
  NOT baked into the layer texture, so a drag does not re-upload. Superseded as
  a non-lane on 2026-09-30: it is now a keyframable lane (see "keyframable
  opacity" below) and the `geom_modified` `u8` bitmask this section called full
  is now exactly full at 8 lanes.
- Persistence: `Saved_Clip.opacity` + an explicit `has_opacity` presence flag
  (Odin JSON pointer fields are unsupported). Old projects load at `1.0`; a
  stored `0` stays a valid fully transparent clip.
- UI: inspector `Opacity` slider + percent field (Clay has no slider, so it is
  `OpacityRow/Track/Fill` with a `SizingPercent` fill). Drag writes live and
  coalesces into a single undo entry on release.
- Preview: `Preview_Slot.opacity` is fed to the layer as a fragment-stage
  uniform; preview already blends `SRC_ALPHA` over the background. The vertex
  and fragment uniform buffers are separate in SDL GPU — the opacity lives in a
  fragment `BlitOpacity` block, not in `Quad_Uniforms`.
- Export: CPU `blend_row` in `render_blit`/`render_blit_region`; GPU
  `blit_box.frag` multiplies the layer alpha by opacity and the composite
  pipeline blends it "over". `skip_canvas_zero` now also fires when any layer
  is translucent (a zeroed canvas would erase what is underneath).
- Probe (`gate.sh opacity`): checks CPU `blend_row` against an independent
  reference mix, and the GPU path against the same mix, at 0/0.25/0.5/0.75/1.0
  — and additionally asserts a fractional opacity actually changes the result.
  `gpu_composite` still pins the opacity=1 end byte-exact.
- The two silent-failure classes this invites — a layer that vanishes (alpha
  reads as 0, so it blends to nothing) and a layer that is ignored (alpha
  never applied) — both render wrong-but-plausible, so the probe asserts the
  mix itself, not merely "non-blank".
- Coupling: `blit_box.frag` now requires a fragment uniform, so every consumer
  that builds the shader itself must pass `num_uniform_buffers = 1` AND push
  the block. The gpu resample probe missed it and the unbound descriptor
  faulted the driver into `VK_ERROR_DEVICE_LOST` on the 4K mip path — a fault,
  not a wrong pixel, which is why it is easy to misread as environmental.

---

## Implemented — keyframable per-clip opacity (2026-09-30)

- Problem: `Clip.opacity` was a resting field only. Every read/write of it
  bypassed the keyframe routing, so a clip that had an opacity track (or that
  auto-key would want one) would show, fill, composite, and persist the wrong
  value depending on which path touched it.
- Model: `.Opacity` is the 8th `Render_Geom_Prop`, named `"opacity"`, grouping
  with no section exactly like `Scale`. It gets a resting field, an optional
  scalar track, the pending bit, and a per-lane Key button from the existing
  machinery instead of a parallel keyframing path. `geom_modified: u8` is now
  exactly full (8 lanes, bit 7 is the high bit) — a 9th property needs the
  field widened to `u16` first.
- One read path, one write path (the invariant clip_geom.odin exists to hold):
  - preview: `slot.opacity` is sampled at the playhead, not read off the field.
  - inspector: reads `clip_geom_get(cl, .Opacity)`, and the slider FILL uses
    that same value, so the fill cannot disagree with the canvas.
  - typed field: goes through `clip_geom_set` (`opacity_field` pointer deleted
    from edit.odin). A direct write there was discarded on any keyed clip.
  - slider drag: `clip_geom_set` on begin and on every move, matching the
    geometry drag; start value and the release-time undo compare both use the
    playhead value.
  - "Key all modified" picks opacity up through the pending bit, and its short
    label is "Opac".
- Export: `render_kf_geom_rect` samples the opacity lane alongside the rect and
  returns it; `render_eval_keyed_geom` writes it into the worker-owned
  `v.opacity` each composite frame, which is the field every blit/blend path
  already reads — so one write covers the CPU blend, the GPU resample, and the
  static-copy path. Clamped 0..1 there, since a key can be dragged out of range.
- Export subtlety: `skip_canvas_zero` is a job-wide decision taken once from
  the render_start snapshot, but a keyed clip can be translucent on a frame
  where the snapshotted resting value read 1.0. So a KEYED opacity lane counts
  as translucent (`opacity_keyed`) — conservative in the safe direction, since
  zeroing the canvas when it was not needed only costs a memset.
- Persistence needed no change: `keyframe_tracks` is a live array on
  `Saved_Clip`, so the opacity track round-trips with the same code as every
  other lane.
- Probe: `render_kf_probe` case F drives a keyed opacity lane through the
  worker's own two steps (`render_geom_name` → `render_kf_geom_rect`) with a
  resting 1.0 and keys fading to 0.25, asserting 1.0 / 0.625 / 0.25 at the
  first/mid/last key. The base is 1.0 precisely so that a lane the worker
  stopped sampling returns 1.0 and fails — that is the silent failure ("keyed,
  but every frame fully opaque") no md5 would catch. Verified by mutation:
  stubbing the sampler to `opacity = base_op` fails F on two checks.
  Also asserts the un-keyed lane falls back to base, which is what keeps
  un-keyed exports byte-identical.
- Note the sampler contract: past a lane's LAST key it is inactive and the
  resting base rules again, so a partial fade returns to the clip's own opacity
  rather than sticking at the last key. Shared with every geometry lane.
- Gates: all 15 functional, all 3 Valgrind (0 definitely/indirectly lost), and
  all 7 export md5s match the pre-change baseline. `geom_key_probe`'s lane
  table is `[int(Render_Geom_Prop._COUNT)]`-sized, so adding a lane is a
  COMPILE error there until its resting value is stated — the enum cannot grow
  a lane the fixtures silently skip.

---

## Implemented — clip tile width is the model's width, not the label's (2026-09-29)

- Symptom: after a cut, the video and audio clips were both 117 frames, but the
  audio clip drew visibly longer; zooming in made it correct. Reported against a
  saved `~/test.vyproj`.
- The data was never wrong: the CBOR showed both clips with
  `source_length_frames = 117`, `timeline_start_frame = 0`, one shared
  `link_id`. So this was a layout defect, not a split defect — worth stating
  plainly, because the report read like a cut bug.
- Root cause: the inner `TimelineClip` tile was `SizingGrow` inside the fixed
  width `TimelineClipWrap`, so the tile took its CONTENT's width — the label at
  `FONT_HEADING` plus `2*CARD_GAP` — whenever the label outgrew the clip. The
  audio clip's default label ("Audio") is one glyph wider than the video's
  ("Clip"), and at a low enough zoom both outgrew the tile. Measured with
  `FONT_HEADING=18`, `CARD_GAP=8`: "Audio" wants 65.5px, "Clip" wants 55.6px,
  matching the laid-out widths exactly. Zooming in made the clip outgrow its own
  label, which is why the size "fixed itself".
- It was not only cosmetic. The tile's box feeds the pointer hit test
  (`interaction.odin` `clay.PointerOver("TimelineClip")`), the drag origin, and
  the marker/waveform pass in `gpu_draw.odin`, so the overflow was clickable and
  draggable — a short clip could swallow clicks belonging to the gap after it.
- Fix: the tile is `SizingFixed(clip_width)` (`ui.odin`) with
  `clip = {horizontal = true}`, so the label is cut to the model width instead of
  sizing it. Affects every clip kind, not just audio.
- Repro: `VYPER_CLIPW_PROBE=<project.vyproj> ./vyper` loads a project and prints
  each clip's laid-out tile width against `frames*zoom` at several zooms. That is
  what found it; it is a manual tool (it needs a user-supplied project), not a
  gate.
- Regression: `ui_probe_clip_tile_width_asserts` runs in `scripts/gate.sh probe`
  over zooms 0.1/0.5/1/4, where the seeded 300-frame clips are narrow enough
  that every label outgrows its tile, and requires
  `tile.width == frames*zoom` for every clip. Confirmed to fail (30px clip laid
  out at 55.6px) with the fix reverted and to pass with it.
- `./scripts/gate.sh check build probe smoke valgrind` pass (`smoke: ok (124)`;
  valgrind 0 definitely/indirectly lost, no invalid access, 22 contexts — the
  probe's project load + `session_teardown` added none).


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

## Implemented — reproducible toolchain via mise, and the two-linker-path bugs behind it (2026-09-29)

The build had stopped working on this host for two unrelated reasons, both of
which produced errors that named the wrong thing.

**1. A stale `ODIN_ROOT` broke every target, not just the build.** It was
exported pointing at `~/.local/lib/Odin`, a hand-installed tree that had since
been emptied, so the compiler aborted with `Invalid ODIN_ROOT, directory does
not exist` — an error naming a missing directory and never mentioning that the
value referred to a compiler that no longer existed. Two scripts needed it and
each had grown its own copy of the fix, so the fix went into
`scripts/toolchain.sh` (`resolve_odin_root`, sourced by both): validate the
value, and if it is not an Odin tree, walk up from the `odin` on PATH to one
that has `base/`. Detected rather than hardcoded, for the same reason `build.sh`
detects mold — the install prefix is a per-host fact.

**2. A missing `clang` failed with `Could not spawn subprocess`.** It is not
optional and not only a "compiled by": it builds `vendor/nanosvg` and
`vendor/clay.c` AND is the driver Odin shells out to at link time. Odin's
`-linker:` flag only selects between its own backends
(`default`/`lld`/`radlink`/`mold`), so there is **no `$CC` override** — gcc
would compile the two C files and then hand the final link back to a clang that
is not installed, failing later and further from the cause. Rejected a
`${CC:-clang}` knob for exactly that reason. `build.sh` now checks for it up
front and names the package.

**The interesting one: mise's clang is a conda build, and that is now solved
rather than worked around.** It links through its own bundled sysroot, which
knows nothing about this host's libraries, so `clang -lavcodec` failed
outright. Forcing `-L/usr/lib` was worse than failing: the link *succeeded*
while leaving avformat's transitive deps (`libswresample.so.7`,
`libavutil.so.61`, `libvpx.so.12`) unresolved — a green build producing a
binary that dies on the first call into ffmpeg. `build.sh` now passes
`--sysroot=/` to the link, which names the root the libraries actually live
under. It is a no-op for a plain system clang and correct for a toolchain
supplied one, so one binary does not need a different invocation depending on
who installed the compiler. Verified end to end: `ldd` shows
`libavcodec.so.63`/`libgio-2.0` from `/usr/lib`, and the headless probe run
completes.

**New tracked file `.mise.toml`**, so the project provisions its own toolchain
rather than depending on a global default that resolves to whatever the host
happens to prefer: `odin` pinned to the exact dev build (a compiler bump changes
codegen, so `latest` makes a red gate unreproducible afterwards), `clang`
pinned (the version actually verified), `mold` pinned (optional — `build.sh`
already falls back — but pinned so every host gets the fast path).
`glslang` and `valgrind` are **not** in it: mise has no backend for either, so
the file documents the pacman packages and why they stay on the system, along
with ffmpeg/sdl3/glib2. Vendoring a second FFmpeg to satisfy a package manager
would mean maintaining a parallel set of structs from `vendor/ffmpeg/` and
hoping the layouts still match — which is what `gate.sh`'s own ABI check exists
to catch.

**Two incidental build fixes.** The C objects now skip when newer than their
source, mirroring the shader rule directly above them; recompiling two files
that never change made a worktree with no artifacts look like a build failure.
And a footgun that only existed because of this work: installing clang through
mise leaves a shim ahead of `/usr/bin` on `PATH`, so it kept shadowing the real
compiler *after* the tool was uninstalled and removed from `.mise.toml`, turning
a correct system clang into `No version is set for shim`. Uninstalling cleared
the shim.

**Found, not fixed — needs a decision.** `scripts/gate.sh`'s `dev()` runs
`dev "$@"` in its nix branch, so on any host that *has* nix installed it
recurses into itself until the stack dies. Unreachable here (`nix` is not
installed, so the host-toolchain branch runs), and the intended invocation is
guessing — `nix develop --command` is not obviously right for a repo that is not
itself a nix package. Left alone rather than half-guessed.

---

## Implemented — key-all-modified as one binding, bounded clip names, Shift keyframe sweep (2026-09-30)

Three inspector/timeline UX changes that share one probe run.

### Key-all-modified: grouped button out, bare `A` in

- Problem: the per-lane `KfAddModified` diamond (`KF_ADD_MODIFIED_ID`) answered
  a real question — a user who pans a plain clip with Alt+drag and then wants to
  animate it would otherwise click seven diamonds — but it sat in a row of
  per-lane diamonds, was the only id outside the `KF_ADD_BTN_IDS` table, and
  cost seven hit tests and a paint for one action.
- `A` is a bare binding (extra modifiers ignored, like the other bare rows), so
  it is a keyboard action, not a 12th inspector element: the button, its id, and
  its hit test are gone, `KF_ADD_BTN_IDS` is `[11]string`, and the
  `KfAllModifiedRow` summary plus its help-overlay entry stay.
- Model: `clip_geom_key_all_modified` samples every on-screen value FIRST, then
  writes. The pending mask is per LANE, not per section, because the honest
  unit of "modified" is one edited property. Packed sections merge same-frame
  lane bits through `kf_geom_set_packed_lane_key`, so a 7-lane pending crop
  becomes 4 keys (l+r, t+b) rather than 7 or 1, all inside ONE undo node.
  Already-unwrapped sections stay unwrapped, and Scale/Opacity stay scalar.
- Probe: `geom_key_probe` grew partial packed masks, cross-section packing, and
  the already-unwrapped case. `ui_probe_action_table_asserts` is 27 cases and
  pins bare `A` plus `Shift+A` and `Ctrl+A` to the same action — the
  most-specific-first walk is where a bare row silently loses to a Ctrl row added
  later, and "A stopped keying" is not a crash anyone would notice.
- Mutation: making the `A` row require Ctrl fails two of the three.

### Bounded clip names in the inspector

- Problem: clay's text element has no maxWidth and no ellipsis option, so a long
  clip name sized its parent and painted the inspector card over the panel
  border. The fix needs two halves because they fail independently.
- Structural half: `INSPECTOR_CARD_MAX_W :: f32(INSPECTOR_MAX_W -
  TSCROLLBAR_W)` caps `card_open`'s grow. Without it, truncation alone leaves the
  card at 346 but `NameValue` still reaches 362.5.
- Textual half: `label_truncate_fmt` cuts to a caller-owned fixed buffer with a
  trailing `...`, reserving the ellipsis first, cutting only on rune
  boundaries (`utf8.Rune_Start`), and asserting the write before the terminator —
  a `[N]u8` copy that silently clips is a wrong label nothing downstream can
  report. No per-frame allocation: `ui_text.clip_name` is `[256]u8`.
- The metric is shared, not duplicated: `FONT_ADVANCE_RATIO :: f32(0.55)` in
  font.odin is the whole of clay's `measure_text`, and `text_px` multiplies by
  it, so the cut lands where clay would have laid the text out.
- `FIELD_PAD_H :: u16(8)` exists because `clip_name_max_px` has to subtract the
  same padding the field's layout adds; two literals for one padding is a
  number that drifts.
- Probe: `ui_probe_inspector_width_asserts` grew a long-name arm on the existing
  45-char fixture. Final geometry — short and long identical at column 356.0,
  card 346.0, `NameValue` 281.1 — and `"A012_C003_20260314_184522_t..."`.
- Mutation: removing the max fails the column check; keeping the max and
  disabling truncation fails the `NameValue` check. Both halves are load-bearing.

### Keyframe select: click-vs-drag, and the hover brush

Two changes to how keyframes are selected, both driven by the same complaint:
the press was doing selection work that only the release can decide.

**Click vs drag on a selected key.** Pressing a key that is already part of a
run used to narrow the selection to that key ON MOUSE-DOWN, so grabbing one key
of a selected run to retime it silently deselected the rest before the drag even
started. A press cannot tell a click from a drag, so it no longer tries:
`narrow_click := kf_sel_contains(grab)` — if the grabbed key is already in the
run, the press preserves the run, captures all of it for the move, and defers the
narrowing to the release. A press on a key OUTSIDE the selection still narrows
immediately (nothing to preserve, and a drag from it must move the key grabbed,
not the old run).

- `Kf_Move` grew `engaged` and `narrow_click`. `engaged` is latched in
  `update_keyframe_drag` the moment the cursor passes `KF_DRAG_THRESHOLD_PX`. It
  is deliberately NOT "did any key move": a drag that returns to its origin, or
  one that only pushes the outermost keys into the clip's clamped edge, moves
  nothing yet is still a drag and must not be read as a click.
- `commit_keyframe_drag` now narrows first when `!engaged`, then runs the move.
- Probe `ui_probe_kf_click_vs_drag_asserts` drives the real press/move/release:
  press keeps the run at 2, drag moves BOTH keys by the same delta and keeps both
  selected, a press+release with no motion narrows to 1 and moves nothing, and a
  press on an unselected key narrows at once.
- Two mutations, both caught: narrowing at press again ("collapsed the run to 1
  keys on mouse-down"), and never narrowing on release ("clicking a selected key
  without dragging left 2 keys selected, want 1").

**The hover brush.** Shift+click on EMPTY keyframe-timeline space arms a
hover-select mode: from then on every keyframe the pointer passes over is ADDED
to the selection, with no button held, and the mode persists after release.
Shift+click ON a keyframe is the opposite — it selects that key and arms
nothing. This is the correction of an earlier implementation that had the two
backwards (sweep armed from a keyframe press, gated on the button being held).

- The brush is a MODE, not an `active_interaction`: that switch is about a held
  button where one gesture runs at a time and ends on release, whereas the brush
  keeps running across unrelated presses. So `Kf_Sweep` was deleted rather than
  adapted, and `kf_brush_armed` / `kf_brush_hovered` are plain globals.
- `kf_brush_paint` runs from `interaction_move` BEFORE the gesture switch, so it
  needs no button and no interaction state. `kf_brush_hovered` is the same
  edge-trigger as before: the pointer rests on whatever key it last crossed, so
  a per-frame version would re-add it forever and the mode could never end
  without also clearing the selection.
- A brush session ACCUMULATES onto the existing selection; arming does not
  clear it. Cancel is Esc or any press without Shift, both central
  (`escape_dismiss`, and the top of `interaction_click_dispatch`) so no
  individual handler has to remember.
- Probe `ui_probe_kf_brush_asserts` asserts the premises too: a Shift+click on a
  keyframe must NOT arm, and hovering must paint nothing while unarmed — else
  the rest would pass while testing the wrong thing. It sets
  `clay.SetPointerState` in its press/hover helpers, exactly as the frame loop
  does, because every clay-gated handler in the chain (`PointerOver(TrackArea)`)
  otherwise reads a stale position and the arming press tests nothing.
- Mutations, all caught: arming from a keyframe click, gating paint on the
  button, clearing the selection on arm, and disarming on release.
- Behavior retained: S7's Shift-drag keyframe MOVE stays unreachable. A
  Shift+click on a keyframe is a plain selection (it does not even arm the
  move), and the brush is entered only from empty space. No replacement gesture
  was invented for it.
- Memory: `kf_brush_hovered` is the same grow-only scratch shape as `kf_hits`;
  `kf_selection_free` hands both back at session teardown.

Both probes fault-inject the same way on purpose: the go-to-keyframe
double-click record is a global on a wall-clock timer, and two probes that press
the same diamond in one process run inside that window, so each probe resets
`kf_dbl_click = {}` on entry. Without it the second press is read as a seek and
never reaches the gesture under test.

Gates: all 10 (`check build geom_key_probe probe transform_probe timeline_probe
valgrind geom_key_valgrind undo_valgrind keyed_export`) pass.

### Unrelated working-tree change

`.mise.toml` also shows `ols` added with `version = "latest"`. Not part of this
work and not reviewed here — flagged because the file's own documented policy
pins `odin`/`clang`/`mold` exactly, on the grounds that `latest` makes a red
gate unreproducible afterwards.

## Implemented — keyed audio gain was applied in the wrong unit (2026-09-30)

- Problem: `~/test.vyproj` opens with an inverted audio blast instead of fading
  in. The clip's gain track holds `-40` at frame 0 and `0` at frame 41 — the
  values the inspector shows and edits in dB — but `audio_mix_frame` took the
  sampled value straight from `kf_sample_keys` and multiplied PCM by it as if it
  were a linear amplitude. `-40` as a multiplier is a −40× inverted signal; the
  static path (`db_to_linear(chip.gain_dB)`) had always converted, so only the
  keyed path disagreed with it.
- Model: the gain track is authored in dB (the inspector's unit — `kf_add_prop`
  keys `cl.gain`), so the CONSUMER converts, exactly as it converts the static
  base. `Play_Seg` gained `gain_dB` (the folded level in the track's unit)
  beside the existing linear `gain`; the mix now samples the curve against
  `gain_dB` and runs it through `db_to_linear`. Both are set wherever `gain` is
  (provision and `audio_gain_fold`). The new `play_seg_gain_linear` holds the
  one conversion so it is unit-testable off the decode path.
- The resting base for a keyed segment is now dB too. Before the first key and
  past the last, `kf_sample_keys` returns the base unchanged; feeding it the
  linear `seg.gain` and then converting would have applied `db_to_linear` twice.
  With `gain_dB` the base is already in the track's unit, so the outside-span
  value converts back to exactly the static `gain` it folded from.
- Probe: `keyframe_probe` builds `db_keys` (the `-40 → 0` dB track from the real
  project) and pins `kf_gain_linear` at frame 0 (`0.01`, not `-40`), on the 0 dB
  key (`1.0`), past the last key (static base), at a keyed midpoint (inside
  `(0.01, 1.0)`, interpolated in amplitude not at the raw dB number), and with
  an empty track (static base, converted). It then routes the SAME track through
  both consumer seams — a `Play_Seg` and a `Render_Audio_Src` — and checks each
  agrees with `kf_gain_linear`, so playback and export cannot silently diverge
  again.
- Mutation: returning the sampled dB value directly (the shipped bug) fails the
  three keyed checks, led by `want linear(-40dB)=0.01000, got -40.00000`.

### Adjacent gap 1 — export mixer applied no per-clip gain (fixed)

- Problem: the export mix loop (`render.odin`, was ~line 2902) added each source's
  PCM into the bus with no multiply at all — neither the static gain nor its
  automation — so a rendered file ignored the gain slider entirely. Found while
  fixing the unit bug above.
- Model: `Render_Audio_Src` gained `gain_dB` plus a copied `kf_keys`/`kf_n`
  snapshot, and the mix evaluates `kf_gain_linear` once per source per timeline
  frame (constant across that frame's samples). Same helper as playback, so the
  two paths share the dB→linear conversion by construction rather than by
  convention. `GAIN_KF_MAX_KEYS` caps the copy; an over-long track warns and
  keeps the first N.
- Testability: the snapshot wiring was pulled out of the job-build switch into
  `render_audio_src_from_clip`, so the part the bug hinged on (the track being
  copied, the static dB being carried) is a unit, not buried in a worker switch.
- Probe: `keyframe_probe` builds a keyed `Clip` and asserts
  `render_audio_src_from_clip` carries `gain_dB`, snapshots all keys, and renders
  the frame-0 keyed gain. Mutations — dropping `gain_dB = clip.gain` ("must carry
  the static clip gain (got 0)") and dropping the `kf_fill_snapshot` block ("must
  snapshot the gain track (got 0 keys)") — are both caught.

### Adjacent gap 2 — inspector gain readout ignored the playhead (fixed)

- Problem: the gain row (`ui.odin`) printed the raw `cl.gain`, while every
  geometry lane prints the playhead-sampled value via `clip_geom_get`. On a keyed
  clip the readout therefore disagreed with what playback was doing.
- Model: new `clip_gain_db_at_playhead` samples the clip's gain track at the
  playhead and falls back to `cl.gain` where the track is inactive (no key,
  before the first, past the last) — the same rule the geometry lanes use.
- Probe: `keyframe_probe` sets the playhead onto the first and last gain keys and
  checks the keyed dB is returned, plus the static value for an unkeyed clip.
  Mutation — returning `clip.gain` unconditionally (the shipped bug) — fails with
  "gain readout on the first key must show the keyed dB, got 0".
- Gates: all 10 (`check build geom_key_probe probe transform_probe timeline_probe
  valgrind geom_key_valgrind undo_valgrind keyed_export`) pass.

---

## Active 13 — Keyframe/marker overlay culled to the visible lane

**Why:** keyframe diamonds and clip markers painted over other panels. They are
drawn by `draw_keyframes` / `draw_clip_markers` (gpu_draw.odin), which run as an
overlay AFTER `render_clay`, because a tile's final position only exists via
`clay.GetElementData`. Being outside the Clay command stream, neither inherits
Clay's scissor stack — each set its own, and each set it to the track's own
`ClipsSection` box.

That box has already been slid by the vertical scroll: `TracksSection` carries
`clip = {vertical = true, childOffset = {0, -timeline_view.top}}` (ui.odin), so
scrolling the track list moved each row's box out from under the viewport along
with the row. Scissoring to it alone therefore covered whatever the row had slid
over — the ruler strip and the panels above the timeline — and the marker lines,
gap triangles and diamonds painted there. Clay clips the same rows correctly
because it walks a scissor stack that nests `TracksSection`'s clip around each
lane; the overlay had to rebuild that intersection and didn't.

Horizontal clipping was already correct (the lane box IS the horizontal viewport),
but nothing culled, so both passes walked every key and every marker of every
clip on every track each frame and paid two/five SDF draws apiece for geometry
the scissor then discarded. At `TIMELINE_MIN_ZOOM` (0.001) a long project's keys
sit megabytes off screen.

Steps:
- [x] S1. Characterization probe first: `ui_probe_marker_cull_asserts` seeds
      markers on every clip (the seed ships none, so the leak had nothing to
      draw and stayed invisible), shrinks the track list until it overflows, and
      asserts for every track that both passes' rect is inside the
      `TracksSection` viewport — across the whole scroll range plus a hard
      overshoot, and at a horizontal scroll that pushes the lane under the
      gutter. Mutation-checked: reverting only the two `box_intersect` calls
      makes it fail on 20+ cases (`track 3 keyframes paints (184.0,1508.0 ...)
      outside viewport (28.0,1332.0 ...)`), which is the shipped defect.
- [x] S2. `tracks_scroll_box` names the one rect every lane overlay must
      intersect (the `TracksSection` box: the viewport Clay clips to AND slides
      the rows by). `kf_lane_rect` / `marker_lane_rect` are the two paintable
      rects, each intersected with it; the marker one unions lane + insert gap
      (where the triangles live) and intersects each half BEFORE the union, so
      an off-viewport gap can't re-widen an already-clipped rect. Empty result is
      the cull signal — both draw loops `continue` on it, so an off-screen track
      costs no draw calls.
- [x] S3. Horizontal culling on top of the scissor, mirroring what the ruler
      already does (`draw_timeline_ruler` breaks out of its tick loop at the
      right edge): a key or marker whose column falls outside the lane is skipped
      before its diamonds/triangles are built. `MARKER_CULL_SLACK` (layout.odin)
      covers the widest thing a marker paints, its 5px gap triangle. Keyframe
      culling reads the frame `kf_sel_frame` returns, i.e. the drag-PREVIEWED
      destination, so a key dragged in from off screen appears immediately rather
      than only at its release.
- Gates: `check build probe timeline_probe transform_probe geom_key_probe
  opacity valgrind` pass. (`zorder`/`keyed_export` cannot run in this checkout:
  they need `target/keyed_export/src.mp4`, a generated fixture no target here
  produces — unrelated to this change.)

### Note on the scissor restore

Both overlay passes restore to the full window rather than to the enclosing
Clay scissor. That is correct today only because `render_clay` also restores to
full (`defer` at gpu_draw.odin:232) and every overlay runs after it. Left as is:
the enclosing scissor is always full at these points, so saving it would be
indirection with no invariant to protect.

---

## Active 14 — Backspace ripple delete + Clip ownership in two procs

**Status: landed 2026-10-03 on `ripple-delete` (base `8c01a84`).**
Numbered 14 on the merge, not 13: `file-dnd` took Active 12 on `main` and
overlay culling took 13, so the three fix branches carry 13/14/15 and no two
headings collide.

**Problem.** Backspace did nothing. `route_key_down` asked
`edit_field_claims_key` before the app action layer, and that proc claimed
Backspace, Return and Escape **unconditionally** — the guard it needed was a
comment saying "the router checks the field state", but the router never did.
So with no field open, an edit field still ate every key a user would use to
delete a clip, dismiss the help overlay, or close a menu. The action table was
fine; the key never got there.

Investigating it turned up the reason it was worth more than one line of
router: **`Clip` is a value struct with three hidden owning fields** — `name`
(heap string), `markers` (entries own a `label`) and `keyframe_tracks` (entries
own a name and a keys backing). So a plain `Clip` copy silently aliases all
three, and the list of things to free on drop had been written out **five**
times for free and **three** times for copy. The two lists already disagreed,
in the two most-used edit verbs in the app:

| Site | Was | Cost |
|---|---|---|
| `delete_selected_clip_raw` | freed markers + keyframes, not `name` | leaked name per raw delete |
| ripple delete, contained-clip case | freed markers + keyframes, not `name` | leaked name per ripple |
| `split_clip_at_playhead` | `right := c^` (value copy) | both halves shared **one** name |
| ripple straddle case | `right := c` **and appended `left` twice** | duplicated clip; shared name/keyframe backing |
| `duplicate_clip` | 25-line hand-written field list | a field added later silently defaulted to zero on the copy |

The name leaks were invisible to the compiler and to every probe; the split
aliasing was a latent double free that the leak was *hiding* (only one free ever
happened). Both are the same defect: a site has to remember a list, and it
already had.

**Steps** (each lands + probe + vet before the next):
- [x] S1. Key routing: `edit_field_claims_key` returns false when
      `edit_state.field == .None`, so Backspace/Return/Escape fall through to
      the app layer. With no field open the router reaches `app_claims_key`; with
      one open the field still owns its three keys.
- [x] S2. Ownership: `clip_deep_copy(src: ^Clip) -> Clip` and
      `clip_payload_free(c: ^Clip)` in `timeline.odin` are now the only way to
      build a Clip from another Clip and the only way to drop one. `clone_timeline`,
      `free_timeline`, `remove_track`, both delete paths, both split paths and
      both duplicate paths call them; the hand-written lists are gone
      (`duplicate_clip` lost 25 lines and can no longer forget a field).
      `clip_payload_free` clears what it frees, so a second call is a no-op.
- [x] S3. Ripple straddle correctness: the right half is deep-copied from the
      **pristine** clip before the left half's edits free the shared backing, it
      re-mints `clip_id`, and `left` is appended exactly once. The old branch
      did all three wrong.
- [x] S4. Keyframe trims: `kf_trim_tail`/`kf_trim_head` replace
      `kf_split_parts` at both split sites. They were needed because the two
      halves no longer share one backing — a helper whose contract is "these two
      clips alias one keys array" has no remaining caller, and keeping it would
      be an invitation to reintroduce the aliasing. The slice-1 remap rule (left
      keeps keys `< F`, right re-relativizes by `-F`, values preserved) is
      unchanged and still probed.

**Probe.**
- `ui_probe_backspace_ripple_asserts`: clicks clip 1 on track 0, presses real
  `sdl.K_BACKSPACE`, asserts the clip is gone, the clip before the cut did not
  move, and the tail slid left by exactly the removed span (the gap closing — the
  actual bug). Also asserts Escape reaches `escape_dismiss` with no field open,
  and that Backspace still edits an **open** number field ("073" → "07"), which
  is the reason the field owns keys at all.
- `ui_probe_key_routing_asserts`: a closed number field claims no key; an open
  one claims exactly Escape, Return, Keypad-Enter and Backspace.
- `timeline_probe` `test_ripple_dispatch_closes_gap`: the same gap-closing
  invariant through `dispatch_action(.Delete_At_Playhead)`, without the mouse.
- `timeline_probe` `test_ripple_straddle_splits_once`: a region strictly inside a
  clip leaves exactly **2** clips (the old branch left 3), with different
  `clip_id`s and the right piece reading the source after the removed span.
- `timeline_probe` `test_split_halves_own_their_payload`: after a split the halves
  have distinct name pointers, one keyframe lane each with one key, distinct
  marker-label pointers, and a keyframe edit on one half does not appear in the
  other.
- Mutations, all caught: restoring the double `append` in the straddle branch
  fails with "a straddle ripple must leave 2 clips (got 3)"; restoring
  `right := c^` in the split segfaults inside the probe (the shared keys backing
  freed by the left half's trim is read by the right half); reverting the S1
  router guard fails the ripple probe with "the gap did NOT close".

**Accept.**
- Gates: `check build probe keyframe_probe timeline_probe transform_probe
  geom_key_probe opacity undo_valgrind valgrind` pass. Valgrind is back to the pre-work baseline exactly —
  `11720 errors from 23 contexts` (FFmpeg/Odin noise), `definitely lost: 0`,
  `indirectly lost: 0`, no invalid free/read/write. `zorder`/`keyed_export` also
  pass on `main` once their deterministic fixture is present — see the Active 15
  note on the missing `dev` wrapper.
- One defect was found *by* the memory gate rather than by a probe: the ripple
  probe snapshotted track 0 with a shallow `Clip` copy to restore it afterwards,
  which aliased payloads the ripple then freed, so the restore handed teardown an
  already-freed name (`free(): invalid size`). The backup is now a
  `clip_deep_copy` and the rebuilt clips are released with `clip_payload_free`.
  Worth recording because the shallow backup looked correct and passed every
  assertion — the probe was green and the process aborted at exit.

**Not done here (deliberately).** `Clip` stays a value struct with owned fields.
The follow-up is to move `name`, marker labels, keyframe track names and keys
into session-owned pools so `Clip` becomes POD data, `clip_deep_copy` becomes a
struct copy, and `clone_timeline` stops allocating. That is a separate
work-stream (it touches project-file load/save, undo snapshots, the renderer and
the ripple rebuild) and should not be smuggled in behind a bug fix.

---

## Active 15 — A/V desync after rapid edits (geometry slab torn read)

**Status: landed 2026-10-03 on `audio-sync` (base `8c01a84`), merged as 15.**
Numbered 15 on the merge because `file-dnd` took Active 12 on `main`; the three
fix branches carry 13 (overlay culling), 14 (Backspace ripple + Clip ownership)
and 15.

**Problem (user):** "try scrubbing around very randomly, creating splits and
ripple deleting, moving around clips and test the playback after it" — playback
after an edit session comes out out of sync. No telemetry available, so the
repro was rebuilt as an assertion.

The audio engine hands its clip geometry to the producer thread through a
double-buffered slab (`audio_geometry_commit` on the UI thread,
`audio_provision` on the producer). The premise of a double buffer is that the
reader's read is short. **This reader's read is not short**: a provision
reopens every decoder synchronously and holds the slot for tens of
milliseconds, while the UI rewrites the slab on every single edit. With two
slots, two commits inside one provision wrap the index around and the second
one lands on the slot the provision is still reading. The provision then builds
its segments from a half-written chip list — `n` already reset, `chip[i]` fields
and the path arena mid-update — so segments carry the wrong source window or
open the wrong file. That is not a glitch, it is the audio playing something
other than what the picture shows: desync.

It is also exactly the reported repro's shape. A provision is tens of ms and an
edit burst commits every few ms, so two commits inside one provision is the
common case, not the rare one.

**Found by probing, not by reading.** Two hypotheses were checked and rejected
first, which is why they are written down:

- *Resync storm* — every edit verb ends in `audio_note_edit` → `audio_seek`,
  which bumps the resync event, and the producer acts on every event change by
  clearing the device queue and reopening all decoders. Measured: **8 edits in a
  burst cause 1 re-provision**, because the burst outruns the 2 ms producer poll
  and collapses into a single event change. Kept as a probe assertion
  (`audio_probe_edit_burst_provisions`) because it is the property that stops a
  future "fix" from making this worse, but it is not the bug.
- *Segment math vs the edited timeline* — checked every provisioned segment's
  source window against the clip that covers it after scrub + split +
  ripple-delete + move. **All agree.** Kept as
  `audio_probe_post_edit_alignment`.

**Steps** (each lands + probe + vet before the next):
- [x] S1. Reproduce the torn read deterministically:
      `audio_probe_geom_slab_handoff` takes the slot exactly as a provision
      does, then commits twice — what a split plus a ripple inside one provision
      does — and asserts the held slot is byte-identical afterwards. Pre-fix it
      fails: the published index wraps to the slot the reader holds and
      `chip0.start` goes 0 → 3000 under it.
- [x] S2. `AUDIO_GEOM_SLOTS = 3` plus an explicit reader claim.
      `audio_geom_acquire` / `audio_geom_release` bracket every producer read;
      `audio_geom_write_slot` picks a slot that is neither the published one nor
      the claimed one. Three slots, at most two excluded, so the writer never
      waits. Claim ordering is load-bearing and documented at the acquire: take
      `idx` first, publish the claim second, or a commit starting in between
      picks the slot the reader is about to read.
- [x] S3. Both reader sites claim: `audio_provision` (with `defer`, so every
      exit releases) and the per-feed `audio_gain_fold` read.
- [x] S4. `audio_probe` gets a gate target. It had none, so nothing ran it —
      the same gap `transform_probe` had. The target synthesizes its own
      deterministic lavfi fixture, so it never depends on a media file someone
      has to supply.
- [x] S5. Telemetry: `audio_rpt.provisions` counts producer-side re-provisions.
      Every one clears the queue and reopens every decoder, so this is the cost
      of telling the engine the timeline changed; it is what makes the burst
      check measurable instead of a vibe.

**Probe / mutation.** `audio_probe_geom_slab_handoff` passes post-fix; making
the writer ignore the reader's claim (`if i != pub`) restores the failure
exactly, which is the mutation that proves the claim is what fixes it and not
the third slot alone.

**Accept.** Gates: `check build probe timeline_probe transform_probe
geom_key_probe opacity audio_probe undo_valgrind valgrind` pass. Valgrind at the
baseline (0 lost, no invalid access, 23 contexts; `11754 errors from 23 contexts`
post-merge, the extra count being the probe code, same 23 contexts).

`zorder`/`keyed_export` looked unrunnable in this environment and were not: their
fixtures are synthesized through a `dev ffmpeg` wrapper that does not exist
here, so the target failed on the missing file, not on an app defect. Generating
the same deterministic lavfi clip with the system ffmpeg and re-running both
targets passes them (`zorder: below=inf hidden under video, above=29.1 drawn over
it`), and `scripts/gate.sh all` exits 0 on `main`. The wrapper is still missing
here — a fresh checkout with no cached fixture will fail these targets on this
box until either `dev` exists or the targets fall back to a system ffmpeg.

**Not fixed here, and named.** Two things this work does not claim:

- The probe proves the *slab handoff* is sound. It cannot prove what the user
  hears; there is no telemetry from a real desync, so if audio still drifts
  after this, the next place to look is the producer's queue/underrun path
  (`wedge_heal`, `skip_full`, `silence_holes` in the report block) with
  `VYPER_AUDIO_LOG=1`.
- The `dev`-less media gates are an environment gap, not a code defect, and
  `keyframes.odin`'s `kf_split_parts` deletion on the ripple branch is not
  mirrored here — that belongs to the branch that owns it.

## Active 17 — Changing the project frame rate silently re-pointed audio clips

**Status: fixed 2026-10-03.** Branch `main` (post-`509d7fd`). `audio_rate` is a
member of `all`. Found while investigating why one audio clip in `baby.vyproj`
was inaudible after the project was switched from 12 fps to 60 fps.

**The defect.** An audio clip's position inside its source FILE was derived by
dividing a frame count by the CURRENT project rate:

```
content_sec := f64(seek_frame - seg.start_a + seg.start_s) / fps
```

An audio file has no frame rate of its own — `media.odin` quantizes its
duration into timeline frames at import — so `source_start_frame` only means
anything against the rate it was authored at. Switching the project to 60 fps
re-divided every audio offset by 5. The clip at `source_start_frame = 35` went
from `35/12 = 2.917 s` to `35/60 = 0.583 s`, and the first ~1.2 s of that file
is digital silence, so the decoder opened, pulled real samples, and every one
of them was silence: `-60.3 dB` mean over the region the clip now pointed at,
against `-10.8 dB` where the scream actually is.

The tell that this is a defect and not a semantic choice: the project's *Siren*
clip has `source_start_frame = 0`, so `0/12 == 0/60` and it kept its content
(and merely sped up). Only clips with a non-zero source offset moved. One button
press, two clips, different damage, nothing logged.

**Why a rate and not a stored offset.** `source_start_frame` is adjusted in
frame space by split, ripple, join and trim (`timeline.odin`, six sites), and it
is compared in frame space for segment contiguity. Storing a second, pinned
offset would mean keeping two representations of one fact in lockstep by hand at
every one of those sites. Pinning the RATE instead keeps the frame number the
single source of truth and lets those sites stay untouched.

**The fix.**

- `Clip.audio_src_rate` — the rate an audio clip's source frames are counted
  against. 0 = unpinned, which falls back to the current rate, i.e. exactly the
  old behavior, so an unpinned clip is never worse than before.
- `Media_Asset.audio_rate` — the exact `timeline_fps()` at import, not one
  recovered by dividing `audio_frames` back out of the duration (that drifts:
  the fixture's 79 frames over 6.6 s gives 11.9697, not 12).
- `audio_source_start_sec` / `audio_content_sec` (`state.odin`) — the one place
  a timeline frame becomes a source-file position. The two terms are different
  kinds of quantity: `frames_into/fps` is a wall-clock distance and follows the
  rate (a clip gets faster, like video), while the pinned start cannot move.
  Collapsing them into `(frames_into + start_s) / fps` is the bug.
- Applied at all six conversion sites: `audio.odin` (provision anchor, demand,
  re-anchor, resync) and `render.odin` (`render_audio_open`, per-frame
  `start48`). Both the chip and `Play_Seg` carry the pin.
- `pf_pin_audio_src_rates` migrates on load, at the only moment the project's
  original rate is still recoverable. A project saved while its rate already
  disagreed with its authoring rate cannot be recovered — nothing in the file
  records the authoring rate — and the effective rate is then the best reading.

The clip still speeds up 5x, which is the accepted consequence of a 5x-faster
timeline and exactly what the `source_start_frame = 0` clip already did; what it
no longer does is change WHICH part of the file is heard.

**Steps / probe / acceptance.** `audio_rate_probe.odin`, wired as
`VYPER_AUDIO_RATE_FIXTURE` (self-contained: the probe synthesizes its own WAV,
silent for 1.2 s then a 1 kHz tone, and builds the project, because the property
under test is a relationship between a rate and an offset and no off-the-shelf
clip is guaranteed to have a non-zero one) and `VYPER_AUDIO_RATE_PROBE` for a
real project.

- Asserts the resolved source start is IDENTICAL at 12/24/30/60/120 fps. A
  loudness check alone cannot: a project whose clips happen to sit on non-silent
  audio would keep passing after the pin reverted to something merely audible.
- Runs a negative control that unpins the clip and REQUIRES it to go silent, so
  the fixture cannot silently stop discriminating while still passing.
- Mutation-verified. Reverting `audio_content_sec` to the original formula:
  `source start moved with the clock: at 60 fps got 0.500000s, pinned
  2.500000s`, clip inaudible, gate exits 1.
- `baby.vyproj` verified end to end: at 60 fps the clip reads `2.917..3.483 s`
  and the exported window carries the scream at `-20.5 dB` mean / `-5.5 dB` max.
  Before the fix the same window was `-65.0 dB`.

**The gate also checks the exported file, and that is not redundant.** The probe
reads the pin off the clip, so it cannot see a render-path regression: breaking
`Render_Audio_Src.source_start_rate` alone leaves the probe PASSING while the
muxed file goes to `-65.0 dB`. `scripts/gate.sh audio_rate` therefore
volumedetects the export (`-7.8 dB` expected, fails below `-30 dB`).

**Pre-existing, not a regression.** `project.frame_rate` already outranked
`timeline.frame_rate` in `timeline_fps()` before the Active 16 work
(`64deb4e~1:state.odin`); that work only repointed the EXPORT at the value the
preview already used. Preview and audio were untouched by it.

**Measurement corrections made along the way, recorded because both first
produced a wrong verdict.** The probe's audibility floor began at peak 64
(-42 dBFS) and called the bug's `peak=162` "AUDIBLE", passing a FAIL; ffmpeg
independently reports that region at `-60 dB` mean. The floor is now 512
(-36 dBFS). The first export comparison used the window 3.50–4.04 s, which
overlaps the Siren clip's tail (it ends at frame 219 = 3.65 s) and reported
`-28 dB` for a build that was actually silent; measured strictly inside the
clip it is `-65.0 dB`.

**Not fixed here, and named.** The clip's gain is a static `-5 dB` in this
project; nothing here exercises the keyed-gain path against a rate change, and
`kf` tracks are keyed in timeline frames, so they retime with the clip the same
way video does. `baby.vyproj` has no keyed gain track to check that against.

## Active 18 — A forward jump decoded through the skipped audio instead of seeking

**Symptom.** Playing `~/Videos/Recordings/2026-10-02/2026-10-02_12-40.mp4`
(AV1 60 fps, 3x FLAC, 6070 s) and moving the playhead forward 10000 frames
(166.7 s): the sound dies. The user's framing is the correct one — the engine
did not die, it *caught up*, and catching up is itself the defect.

**Cause, from the engine's own telemetry** (`VYPER_AUDIO_LOG=500
VYPER_AUDIO_FULL=1`) at the jump:

```
t=20.84s ph=78044 anchor=77735 prod=77751 skew=-5.133s mix=5243.0ms under=540 clr=3
  [src 0] first48=62200800 have48=62201856 fifo=1056fr decoded=62201856fr/15186ch
```

`mix=5243.0ms` is one `audio_mix_frame` call spending 5.2 s of producer-thread
time inside a 500 ms report window, and `decoded=62201856fr` is all 166 s of
FLAC decoded (15186 chunks) to travel 10000 frames. `under=540` is the device
eating the result: a blocked producer with an emptied queue underruns, which is
the "dies" the user hears.

`audio_mix_frame` re-anchored a source whenever the fifo head was *ahead* of the
demand, but had no case for the demand being far *ahead* of what the decoder
held — so it pulled the gap one chunk at a time. The forward-skip in
`audio_producer_feed` is deliberately not a re-provision (reopening every
decoder on every forward move is the restart storm Active 14/15 removed), which
left decode-through as the only way forward.

**Fix.** `AUDIO_FORWARD_DECODE_MAX_SEC` (1 s) bounds how much skipped audio a
forward move may buy by decoding rather than seeking. Under it, decoding in
place stays cheaper than a seek and the existing behaviour is unchanged; over
it, `audio_mix_frame` re-anchors the source with `audio_src_seek_anchor`, the
same call the behind-the-head case already used. Sized at the crossover
measured here: FLAC decodes ~160x realtime (~6 ms per source per second), and
a seek costs one preroll decode plus the seek. Mirrors `FORWARD_STREAM_MAX_SEC`
on the video side, which streams instead of seeks only inside the same bound.

The two directions also now share one clamp, since a seek lands on the decoder's
real PTS and rounding can put it either side of the demand.

**Measured on the user's file, 10000-frame jump, 5 sources:**

| | before | after |
|---|---|---|
| wall time in `audio_mix_frame` | 937.7 ms | 4.0 ms |
| decoded frames | 7,999,488 (166.7 s) | 53,248 (1.1 s) |

**Gate.** `audio_probe_forward_jump` asserts the jump SEEKS rather than
decoding through: the decode budget is the gap up to the bound, plus the seek
preroll, plus the frames actually asked for, plus one decoder frame of chunk
overshoot. Silent frames right after the jump fail the same case — there is no
"it needed a moment" case. Mutation-verified: forcing the head-behind test
false gives `decoded 7999488` on the real file and `241664` on the fixture,
against a budget of `144000`.

It runs in its own process (`VYPER_AUDIO_JUMP_PROBE`, wired into
`target_audio_probe`) because it re-imports the source onto a clean timeline:
appended to the split-and-ripple-deleted timeline the earlier cases leave
behind, it measured that mess and reported "nothing decodes at frame 0". Its
gap is derived from the clip (`JUMP_GAP_SEC`, 5 s) rather than the user's
10000 frames, because the fixture is 10 s long and a 166 s gap can only skip —
a probe that skips is not a gate. The 10000-frame case stays available:
`VYPER_AUDIO_JUMP_PROBE="<file>|10000"`.

**Not fixed here, and named.** The AV1 `libdav1d` "Missing reference frame
needed for show_existing_frame" scrub error is a separate, unreproduced defect.
An isolated `decode_source_frame` walk over `baby.vyproj`'s webm — 657
sequential/random/reverse requests — produced zero failures, zero libdav1d
errors and zero send/recv errors, and CLI seeks are clean too, so it does not
reproduce in the shipped source-decode path. Whatever emits it is in the live
async/proxy path, not `decode_source_frame`. The probe that walked the source
is parked at `/tmp/opencode/av1-scaffold/` rather than shipped, since a gate
for a bug that was not found is noise.

## Active 19 — `Clip` as POD: session pools for names, labels, keyframe keys

**Status: S0, S1 and S2a landed.** S2b (the key array store) is next. Numbered 19 rather than
16 because main took 16 (export rate), 17 (audio rate) and 18 (forward jump)
while this plan sat on its own branch.

**Why.** `Clip` (`state.odin:338`) is a value struct with three heap-owning
fields: `name: string`, `markers: [dynamic]Clip_Marker` (each `label: string`),
and `keyframe_tracks: [dynamic]Kf_Track` (each `name: string` plus a
`[dynamic]Keyframe`). Everything expensive about copying a clip follows from
that: `clip_deep_copy` (`timeline.odin:733`) clones the name, rebuilds the
marker slice and re-keys every track via `kf_clone_mut`, and `clip_payload_free`
(`timeline.odin:754`) has to be called on every drop path. Active 14 (Backspace
ripple + ownership) had to route ten-plus sites through those two procs, and
that was only correct because the audit found them all — the compiler cannot see
a forgotten free, and the next clip field that grows a payload re-opens the same
class of bug. A POD `Clip` makes the copy `src^` and deletes both procs.

**Boundary facts to confirm first (step 0).** The whole plan rests on two
assumptions; if either is false the shape changes, so verify before writing code:
- Do undo snapshots outlive the session, or get written to disk? Today they are
  deep copies held in memory (`undo.odin`), which is what makes pools safe. If a
  snapshot is ever persisted or restored into a fresh session, it must
  re-materialize strings on restore and borrowed offsets are wrong.
- Does anything hold a `Clip` across a project `:open`/`:new`? A pool reset
  invalidates every offset at once, so a surviving `Clip` would read another
  project's strings. If one exists, the reset needs a generation check rather
  than a blind clear.

**Constraint, decided.** The project file format does not change.
`Saved_Clip` (`project_file.odin:70`) keeps serializing names, labels and keys by
value; the pools are session-only and invisible to save/load. An old project
must load byte-identically after this work.

**Steps** (each lands + probe + vet before the next):
- [x] S0. **Confirmed, both assumptions hold.** Undo snapshots are in-memory
      only: `Undo_Node.snap`/`Undo_History.pending` live in `undo_hist.slots`,
      nothing in `undo.odin` touches disk, `session_teardown` calls
      `undo_free_all`, and `undo_init` (called on project load) frees the old
      history before snapshotting a new baseline. No snapshot is restored across
      projects, so a pool reset can never strand one. No `Clip` value survives a
      reset either: the persistent `^Clip` references found are transient
      drag/preview state and `PlannedMove.clip` is temp-allocator scoped.
      Consequence: the reset is a blind rewind, with an assert on the read side
      to catch a stale handle rather than a generation tag.
- [x] S1. **Landed.** `session_str.odin`: one fixed-size session block, `Clip.name`
      and `Clip_Marker.label` are now `Session_Str_Handle{off, len}`, read via
      `clip_name`/`marker_label`, written via `clip_set_name`/`marker_set_label`.
      `clip_deep_copy`'s name clone and `clip_payload_free`'s name delete are
      gone; `free_markers` no longer frees labels; `clone_marker` is `m^`.

      **The block is fixed-size, not grow-only, and the probe is why.** The plan
      said "grow-only". Implemented as a `[dynamic]u8` first, it was wrong:
      `session_str_view` hands out a `string` ALIASING the pool, and the first
      append that reallocated left every captured view dangling — `timeline_probe`
      read a label back as `áúY...`. No call-site care fixes that,
      because a caller cannot tell a moved buffer from a live one. So the pool is
      a fixed 1 MiB block carved by a bump pointer: published bytes never move,
      which is what makes an alias valid for the session. Exhaustion is an assert
      naming `SESSION_STR_POOL_BYTES`, not a reallocation. Mutation-confirmed:
      reverting to `[dynamic]` fails the view-survival check with garbage.

      **Format constraint held, but only just.** `Saved_Clip.markers` was typed
      `[dynamic]Clip_Marker` precisely because the live type was cbor-safe. A pool
      handle is not, so that reuse would have silently written two i32s where the
      file stores a string — every saved project would fail to load. Fixed with an
      explicit `Saved_Marker` DTO (same field names/types, so bytes are
      unchanged) plus `saved_markers`, and pinned by a probe assertion that greps
      the written file for the label text: a struct of two i32s cannot contain it.
      Mutation-confirmed: reverting the DTO fails that check.

      **Two leaks found and fixed on the way.** `saved_markers` allocates a DTO
      array per clip (the live-array alias it replaced was free), so
      `project_file_free_containers` now frees them — the memory gate caught it at
      8,481 bytes in 135 blocks and is now back to 0/0. And `fmt.println` takes
      `any`, so two `parity_probe` sites passing `clip.name` still COMPILED after
      the type change while printing a struct instead of the clip's name: the
      compiler-driven sweep has a hole wherever a value flows into `any`.

      **One probe premise inverted on purpose.** `test_split_halves_own_their_payload`
      asserted `raw_data(left.name) != raw_data(right.name)` — pointer inequality,
      i.e. "the halves must NOT share". Sharing is now the point, so that check
      became the stronger isolation test: rename the left half, assert the right
      still reads the original name.
- [x] S2a. **Landed.** `Kf_Track.name` is a `Session_Str_Handle` like `Clip.name`
      (`keyframes.odin`), read via `kf_track_name`, written via
      `kf_track_set_name`/`session_str_intern`. `Kf_Track.keys` is STILL an owned
      `[dynamic]Keyframe` — the store is S2b. The `delete(track.name)` pairs are
      gone from `kf_free_tracks`, `kf_del_key`, the render fold/expand paths and
      the geometry/undo probes; the key arrays they used to free alongside are
      untouched.

      **The second DTO landmine was real, and it is now pinned.** As predicted
      under S1, `Saved_Clip.keyframe_tracks` was typed `[dynamic]Kf_Track` — a
      handle where the file stores a name. Fixed with an explicit
      `Saved_Kf_Track{name: string, keys: [dynamic]Keyframe}` (identical CBOR
      shape), `saved_kf_tracks`, interning on load, and a free of the DTO arrays
      at the save boundary. Only `name` needed the DTO: `[dynamic]Keyframe` is
      still cbor-safe (scalars plus a fixed-array union variant), and that stops
      being true in S2b. Mutation-confirmed twice over: aliasing the live
      `Kf_Track` and keeping the handle raw fails the project round-trip
      (`scalar kf track mismatch`, probe rc=1), and the probe now greps the
      written file for the lane name the way it already did for the marker label.

      **`kf_track_index` compares TEXT, deliberately not interned handles.**
      The obvious conversion — `session_str_intern(name)` then compare handles —
      is wrong: callers pass compile-time constant section names and one of them
      (`render.odin`) asserts a track is ABSENT before minting it, so interning
      would grow the session pool from a lookup. `clip_geom` evaluates this per
      frame: a write on a read path, and pool bytes leaked per distinct
      never-present name. Comparing the borrowed view against the argument is
      side-effect-free and costs one compare over a handful of lanes. Handle
      equality is only faster for a caller that ALREADY holds a handle, and no
      such caller exists yet — `Kf_Snap.name` is the one place a lane name
      crosses into a still-owned heap string, and it keeps its clone.
- [ ] S2b. Keyframe keys into the session arena: `Kf_Track.keys` becomes
      `(off, len)` into one `[dynamic]Keyframe` store per session. This is the
      risky step — it lands right after the Active 14 split/trim/undo work, which
      is the code most likely to regress — so it goes in alone, behind the
      existing `keyframe_probe`, and ~200 `.keys` sites move.

      **Carry S1's lesson in:** a `[dynamic]Keyframe` store is safe to reallocate
      ONLY because a track's handle is an INDEX, not a pointer into it. Do not
      add an accessor that hands out a borrowed `[]Keyframe` — several current
      callers read `track.keys` as a slice and a realloc mid-read would dangle
      exactly like S1's view. Index instead, or read through a guard that
      re-resolves after any mutation.

      **Two things this must answer, both unresolved:** (a) the store is
      per-session and shared, so two `Clip`s that copied a track now share one
      range — a write to one must not be visible in the other, which means
      copy-on-write with an explicit shared flag (no refcount: the owner is the
      session, the mutator is decided by the write path); (b) `Clip` is not POD
      until `clip.keyframe_tracks` itself stops being an owned `[dynamic]`, and
      that array is the same COW question one level up. S3's "collapse to
      `c := src^`" is not reachable until both are, so do not start S3 first.
- [ ] S3. Delete `clip_deep_copy` and `clip_payload_free`, collapse every copy
      site to `c := src^`, and delete the now-empty free paths. A `Clip` copy
      must become a plain struct copy with no proc in between; if a site still
      calls a copy proc, the field it was copying is still owned somewhere.
- [ ] S4. `clone_timeline` stops allocating for clip payloads.

**Probe / mutation.** Per step, the existing probes are the regression net
(`keyframe_probe`, `timeline_probe`, `probe`, `undo_valgrind`) and the memory
gate is the ownership proof: a borrowed-offset `Clip` has nothing to leak, so
valgrind's counts must not move — a change there means a payload is still being
owned somewhere the plan missed. Mutations to prove each step bites: interning
by pointer instead of offset (two clips with equal names must share storage and
a rename must not touch the other), and a pool reset without the generation check
from S0 (a stale offset must fail loudly, not read another project's string).

**Accept.** `check build probe keyframe_probe timeline_probe transform_probe
geom_key_probe opacity audio_probe valgrind undo_valgrind` all pass; valgrind at
the current baseline (23 contexts, 0 lost, no invalid access). `clip_deep_copy`
and `clip_payload_free` are gone from the tree, `rg` shows no remaining per-clip
payload free, and `:save`/`:open` round-trips a project with names, markers and
keyframes unchanged — verified by loading a fixture written before this branch
existed, not one written by it.

**Not claimed.** This does not make `Clip` immutable or shared: two `Clip`s that
share a name offset share the string, so any future in-place rename must go
through copy-on-write, and the inspector rename path has to re-intern rather
than write through. Step 1's interning has to make that explicit before S3
removes the last code that copied on write.
