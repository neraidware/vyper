package main

import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"

// ---------------------------------------------------------------------------
// Preview slot lifecycle: assigning a Preview_Slot to each video clip that
// covers the playhead, driving decode, and looking slots up by clip identity.
// ---------------------------------------------------------------------------

// WARM_LOOKAHEAD is how many frames before the end of the current front clip
// the prewarm kicks in (in timeline frames). At 60fps, 120 frames = 2s.
WARM_LOOKAHEAD :: 120

// warm_decoder pre-opens the clip that will play next (the one starting flush
// at -- or first after -- the current front video clip's end) and pre-decodes
// its first few frames while the current clip is still playing. When the
// playhead crosses the boundary, update_preview_slots hands this warm decoder
// to the slot so the transition is a cache hit instead of a cold
// reopen + keyframe-to-target seek that stalls the render loop exactly at the
// cut. The cold seek itself is absorbed earlier, during the tail of the
// current clip, where the dropped-frame preview tolerates a skip.
warm_decoder: Clip_Decoder
warm_buf: [PREVIEW_W * PREVIEW_H * 4]u8
warm_clip_id: u64
warm_valid: bool

// next_clip_on_track returns the next VIDEO clip on `track` starting at
// `start_idx` whose timeline kickoff is at/after `at_or_after` (the earliest
// such). Non-video clips (text, generators) are excluded: they have no
// decodable source file, so warming "into" one is meaningless -- and their
// path is legitimately nil, which would make the decode open a NULL filename.
next_clip_on_track :: proc(track: ^Track, start_idx: int, at_or_after: i64) -> ^Clip {
	best: ^Clip
	best_start := max(i64)
	for i := start_idx; i < len(track.clips); i += 1 {
		c := &track.clips[i]
		if c.kind != .Video || c.path == nil {
			continue
		}
		if c.timeline_start_frame < at_or_after {
			continue
		}
		if c.timeline_start_frame < best_start {
			best_start = c.timeline_start_frame
			best = c
		}
	}
	return best
}

// prewarm_next_clip warms the decoder for the clip that will play after the
// current front video clip, but only during forward playback and only within
// WARM_LOOKAHEAD frames of the boundary. No-op while paused/scrubbing (no
// wasted seeks) and when no upcoming clip exists.
prewarm_next_clip :: proc() {
	if !playhead.playing || playback_dir != 1 {
		return
	}
	for t := 0; t < len(timeline.tracks); t += 1 {
		track := &timeline.tracks[t]
		for i := 0; i < len(track.clips); i += 1 {
			c := &track.clips[i]
			if c.kind != .Video {
				continue
			}
			if playhead.frame < c.timeline_start_frame || playhead.frame >= c.timeline_start_frame + c.source_length_frames {
				continue
			}
			// c is the frontmost active video clip; warm what plays next on this track.
			end := c.timeline_start_frame + c.source_length_frames
			if end - playhead.frame > WARM_LOOKAHEAD {
				return
			}
			next := next_clip_on_track(track, i, end)
			if next == nil {
				return
			}
			// Adjacent same-asset hop (split halves, duplicated clips): the slot's
			// decoder-preserve path (update_preview_slots) already turns it into a
			// single cheap forward decode, so a pre-open here would be wasted work
			// (an extra open + keyframe seek into the file during the current
			// clip's tail). Only pre-warm when the boundary is a source-index gap
			// or a cross-asset leap -- the cases that would otherwise cold-seek.
			if next.path == c.path && next.source_start_frame == c.source_start_frame + c.source_length_frames {
				return
			}
			if warm_valid && warm_clip_id == next.clip_id {
				// Target unchanged; nothing new to decode (cached frames persist).
				return
			}
			if warm_valid {
				clip_decoder_reset(&warm_decoder)
				warm_valid = false
			}
			warm_proxy_buf: [4096]u8
			// Resolve the preview target PER FRAME (segmented proxies grow as
			// the background builder lands more segments); each decoded warm
			// frame may come from a different segment than the last, and the
			// decoder reopens when the physical file changes.
			warm_pick, warm_base := proxy_pick_for_frame(next.path, next.source_length_frames, next.source_start_frame, warm_proxy_buf[:])
			decoder_set_preview(&warm_decoder, warm_pick, warm_base)
			if !decode_clip_frame_sync(&warm_decoder, next.path, next.source_start_frame, warm_buf[:]) {
				return
			}
			// Buttress the cache with a few following frames (cheap forward steps).
			for kf in i64(1) ..< 4 {
				wf := next.source_start_frame + kf
				warm_pick, warm_base = proxy_pick_for_frame(next.path, next.source_length_frames, wf, warm_proxy_buf[:])
				decoder_set_preview(&warm_decoder, warm_pick, warm_base)
				if !decode_clip_frame_sync(&warm_decoder, next.path, wf, warm_buf[:]) {
					break
				}
			}
			warm_clip_id = next.clip_id
			warm_valid = true
			return
		}
	}
}

// update_preview_slots walks every video clip covering the current playhead and
// ensures each has a Preview_Slot with its frame decoded (using the slot's RAM
// frame cache). Slots are reassigned by index each frame; when a slot's clip
// identity changes its decoder is reset and reopened. Returns true if any
// frame changed (caller re-uploads textures).
update_preview_slots :: proc() -> bool {
	changed := false
	next_slot := 0
	// front_video_slot is the lowest-index slot holding a non-text clip at the
	// playhead: the foreground face. Only it is decoded on the async worker
	// (probe mode below waits for the result); all other slots decode
	// synchronously.
	front_video_slot := -1
	if dragging_playhead {
		scrub_tick += 1
	}
	// Warm the upcoming clip's decoder before the playhead crosses the
	// boundary, so the transition hands over a warm decoder (no cut stall).
	prewarm_next_clip()
	for track_idx := 0; track_idx < len(timeline.tracks) && next_slot < MAX_PREVIEW_SLOTS; track_idx += 1 {
		track := &timeline.tracks[track_idx]
		for i := 0; i < len(track.clips) && next_slot < MAX_PREVIEW_SLOTS; i += 1 {
			clip := &track.clips[i]
			if clip.kind != .Video && clip.kind != .Text {
				continue
			}
			frame := playhead.frame
			if frame < clip.timeline_start_frame || frame >= clip.timeline_start_frame + clip.source_length_frames {
				continue
			}
			slot := &preview_slots[next_slot]
			slot_idx := next_slot
			next_slot += 1
			if clip.kind != .Text && front_video_slot < 0 {
				front_video_slot = slot_idx
			}
			// Identity is the clip instance (clip_id), not its asset or its
			// position: asset_id alone would conflate two different clips of
			// the same source file, and timeline_start_frame changes under a
			// drag, which is exactly the identity a dragged clip needs to KEEP.
			// The decoder and its source-frame-keyed RAM cache stay intact
			// across a same-clip position change (a drag): the clip_frame
			// request below shifts with the new position and the cache still
			// serves it (adjacent frames) or the decoder seeks once.
			if !slot.in_use || slot.clip_id != clip.clip_id {
				// Reassigning the slot to a different clip identity. When the new
				// clip references the SAME source asset as the one the slot was
				// decoding, keep the decoder open and its RAM cache warm: a flush
				// boundary between two clips of one file (split halves,
				// duplicates) transitions into the next clip at the file's
				// adjacent frame, which is then a single fast forward decode
				// instead of a reset + reopen + keyframe-to-target seek that
				// spikes the render loop (the transition lag). Only a genuinely
				// different source file needs the decoder torn down. A warm
				// decoder prepared by prewarm_next_clip for EXACTLY this clip
				// takes precedence -- it already holds this clip's first frames
				// decoded (instant boundary), whereas the preserved decoder would
				// still have to seek across a source gap.
				warm_hit := warm_valid && warm_clip_id == clip.clip_id
				same_asset := slot.in_use && !warm_hit && slot.path == clip.path
				saved_dec := slot.dec
				if slot.in_use && !same_asset {
					clip_decoder_reset(&slot.dec)
				}
				// A text slot owns its tight GPU texture; the zeroing below would
				// orphan it (no device here to release it), so stash it for the
				// render loop and free the CPU buffers now.
				if slot.is_text && slot.texture != nil {
					queue_text_texture_release(slot.texture)
				}
				if slot.text_buf != nil {
					delete(slot.text_buf)
					slot.text_buf = nil
				}
				if slot.text_base_buf != nil {
					delete(slot.text_base_buf)
					slot.text_base_buf = nil
				}
				if slot.text_scratch != nil {
					delete(slot.text_scratch)
					slot.text_scratch = nil
				}
				slot^ = {}
				if same_asset {
					slot.dec = saved_dec
				} else if warm_hit {
					slot.dec = warm_decoder
					warm_decoder = {}
					warm_valid = false
					warm_clip_id = 0
				}
				if warm_hit {
					slot.prime_from_warm = true
				}
				slot.in_use = true
				slot.clip_id = clip.clip_id
				slot.asset_id = clip.asset_id
				slot.path = clip.path
				slot.tex_dirty = true
				if nered_trace {
					fmt.printf("[vf] assign slot=%d asset=%d tl=%d src=%d len=%d playing=%v same_asset=%v warm_hit=%v clip_id=%d warm_id=%d\n",
						next_slot - 1, clip.asset_id, clip.timeline_start_frame, clip.source_start_frame, clip.source_length_frames, playhead.playing, same_asset, warm_hit, clip.clip_id, warm_clip_id)
				}
				mem.zero(raw_data(slot.buffer[:]), len(slot.buffer))
			}
			// A position/source shift makes the slot's frontier (timeline-keyed
			// forward splice point) invalid: if we keep it, a clip moved forward
			// gets clamped to req = frontier+1 which maps BELOW its new start.
			// Within EITHER mapping the exact-playhead frame shown is the right
			// one, so decode exactly once without the forward-drop clamp (the
			// source-frame cache still makes it cheap).
			anchor_shifted := slot.timeline_start_frame != clip.timeline_start_frame || slot.source_start_frame != clip.source_start_frame
			if nered_trace && anchor_shifted {
				fmt.printf("[vf] SHIFT asset=%d tl=%d->%d src=%d->%d playing=%v\n",
					clip.asset_id, slot.timeline_start_frame, clip.timeline_start_frame, slot.source_start_frame, clip.source_start_frame, playhead.playing)
			}
			slot.timeline_start_frame = clip.timeline_start_frame
			slot.source_start_frame = clip.source_start_frame
			if anchor_shifted {
				// A clip was moved (drag) or its source window changed. The
				// slot's decoded buffer + texture still hold the OLD position's
				// pixels. Until a frame is decoded for the CURRENT position,
				// has_frame must be false and the buffer zeroed, or
				// draw_preview keeps painting the stale image (same-asset
				// switches — e.g. split halves moving — don't reset the slot's
				// decoder, so without this the old clip's face lingers).
				// Decode advances the frontier invalid too, so request the
				// exact playhead frame once, then normal dropped-frame resume.
				slot.has_frame = false
				slot.tex_dirty = false
				slot.have_frontier = false
				mem.zero(raw_data(slot.buffer[:]), len(slot.buffer))
			}
			slot.transform_x = clip.transform_x
			slot.transform_y = clip.transform_y
			slot.scale = clip.scale
			slot.crop_l = clip.crop_l
			slot.crop_r = clip.crop_r
			slot.crop_t = clip.crop_t
			slot.crop_b = clip.crop_b
			slot.source_w = clip.source_w
			slot.source_h = clip.source_h
			// Text clips have no decoder or source frame: the buffer is the
			// whole preview canvas with the title rasterized at its top-left by
			// textclip.odin. Re-render only when the title (its hash) changes so
			// the buffer + GPU texture stay in sync with the clip's name and a
			// rename (even unpaused) triggers one re-upload.
			if clip.kind == .Text {
				if clip.generator == .Subtitles {
					// Subtitle generator: the output is the active .srt cue's
					// text, not the clip's name. update_subtitle_slot owns the
					// whole raster + re-center lifecycle (see above).
					slot.is_text = true
					slot.crop_l = 0
					slot.crop_r = 0
					slot.crop_t = 0
					slot.crop_b = 0
					if update_subtitle_slot(slot, clip, frame) {
						changed = true
					}
					continue
				}
				// The tight, top-left bounding box. Text size has TWO decoupled
				// notions: clip.source_w/h are the BASE tight ink dims at font 48
				// (constant per title), and clip.scale is the pure multiplier that
				// drives both the logical box (source_w * f * scale) and the raster
				// RESOLUTION (the title is re-rendered at font = 48*scale so the
				// glyphs scale crisply instead of upscaling a fixed 48px frame).
				// Keeping source_w/h as the scale-independent base is what lets the
				// handle-drag math compute an absolute new scale from a fixed base —
				// if source_w/h carried the baked size, the drag would double-count.
				slot.is_text = true
				slot.crop_l = 0
				slot.crop_r = 0
				slot.crop_t = 0
				slot.crop_b = 0
				name_hash := text_clip_hash(clip.name)
				base_changed := slot.text_hash != name_hash
				font_px := f32(TEXT_CLIP_FONT_PIXELS) * clip.scale
				if base_changed {
					// Re-measure the base tight dims at font 48 on rename.
					base_bw, base_bh := text_buf_size_for(clip.name, TEXT_CLIP_FONT_PIXELS)
					need_base := base_bw * base_bh * 4
					if need_base > len(slot.text_base_buf) {
						delete(slot.text_base_buf)
						slot.text_base_buf = make([]u8, need_base)
					}
					if len(slot.text_scratch) < text_scratch_size_for(TEXT_CLIP_FONT_PIXELS) {
						delete(slot.text_scratch)
						slot.text_scratch = make([]u8, text_scratch_size_for(TEXT_CLIP_FONT_PIXELS))
					}
					_, _, bw0, bh0 := rasterize_title_into_buffer(clip.name, slot.text_base_buf, base_bw, base_bh, &text_clip_font, &text_clip_font_init, slot.text_scratch, TEXT_CLIP_FONT_PIXELS)
					clip.source_w = c.int(bw0)
					clip.source_h = c.int(bh0)
					slot.source_w = c.int(bw0)
					slot.source_h = c.int(bh0)
					slot.text_hash = name_hash
				}
				if base_changed || slot.text_font_px != font_px {
					// Re-render at the baked font (48*scale) for the texture.
					slot.text_font_px = font_px
					need_sc := text_scratch_size_for(font_px)
					if need_sc > len(slot.text_scratch) {
						delete(slot.text_scratch)
						slot.text_scratch = make([]u8, need_sc)
					}
					bw, bh := text_buf_size_for(clip.name, font_px)
					need := bw * bh * 4
					if need > len(slot.text_buf) {
						delete(slot.text_buf)
						slot.text_buf = make([]u8, need)
					}
					text_x, text_y, text_w, text_h := rasterize_title_into_buffer(clip.name, slot.text_buf, bw, bh, &text_clip_font, &text_clip_font_init, slot.text_scratch, font_px)
					slot.text_x = text_x
					slot.text_y = text_y
					slot.text_w = text_w
					slot.text_h = text_h
					// The texture is the FULL estimated buffer (bw x bh), so the
					// upload + UV sampling work against it; the draw samples only
					// the tight ink sub-rect (text_x/text_y/text_w/text_h).
					slot.text_tex_w = c.int(bw)
					slot.text_tex_h = c.int(bh)
					slot.has_frame = text_w > 0 && text_h > 0
					slot.tex_dirty = true
					slot.text_recreate = true
					changed = true
				}
				if !slot.has_frame || slot.text_w <= 0 || slot.text_h <= 0 {
					continue
				}
				continue
			}
			// While playing, decode forward as fast as decode allows and show
			// whatever the newest decoded frame is (dropped-frame preview: real
			// speed, stutter when slow, never slow-motion). When paused, exact
			// frames are requested for scrubbing. The frontier is per-slot so
			// moving a clip to an earlier point (or switching clips) never gets
			// frozen on stale content: skip only when the playhead sits AHEAD of
			// this slot's own frontier, never behind it.
			req := frame
			if playhead.playing && playback_dir == 1 {
				if slot.have_frontier && req > slot.frontier + 1 {
					if req - slot.frontier <= PLAYBACK_CATCHUP_FRAMES {
						// Within the drift budget: take the cheap +1 forward
						// step (adjacent decode, no re-seek).
						req = slot.frontier + 1
					}
					// Frontier fell further behind than PLAYBACK_CATCHUP_FRAMES
					// (decode could not keep real time -- e.g. source fallback
					// while a segment builds). Drop the intervening frames and
					// decode the CURRENT playhead instead of crawling +1 forever:
					// the unbounded crawl is what made video linger on a stale
					// face for seconds while audio played on. A dropped-frame
					// re-seek bounds A/V drift to the budget; on an all-intra
					// proxy it is one keyframe decode, after which the frontier
					// re-pins to the playhead and the next request is the +1
					// forward step again. The front slot posts this to the async
					// worker (no loop block); background slots decode it once.
				}
			}
			// Scrub throttle: a drag fires many mousemoves, and dropping the
			// frontier below forces an exact-seek decode per UI frame per slot.
			// Decimate: decode exact frames on every SCRUB_DECIMATION-th update
			// only, showing the last decoded face between. The foreground slot
			// is exempt when its decode runs on the async worker: that path is
			// non-blocking, so it chases the pointer every update and scrubbing
			// the visible face stays live. A slot that has not yet covered its
			// current frame still decodes on the first throttled tick so a clip
			// crossing the playhead mid-drag shows immediately.
			scrub_skip := dragging_playhead && scrub_tick % SCRUB_DECIMATION != 0 && (slot_idx != front_video_slot || !async_has_worker())
			clip_frame := clip.source_start_frame + req - clip.timeline_start_frame
			// Resolve the preview target PER FRAME: a segmented proxy grows as
			// the background builder lands more segments, so the frame the
			// decoder serves may switch files (segment N -> source, or N -> N+1)
			// as the playhead crosses a segment boundary mid-build. The decoder
			// reopens on the physical-file change; render/probe paths are
			// unaffected because they never set a preview target.
			pick_buf: [4096]u8
			slot_pick, slot_base := proxy_pick_for_frame(clip.path, clip.source_length_frames, clip_frame, pick_buf[:])
			if !scrub_skip || !slot.has_frame {
if slot_idx == front_video_slot && async_has_worker() {
					if slot.prime_from_warm {
						// Transition frame: the decoder handed over by prewarm
						// already holds this clip's first frames in its RAM cache,
						// so serve this one synchronously (a pure cache hit) and
						// set has_frame immediately. Posting to the worker here
						// would leave the freshly-reassigned slot dark while its
						// cold decoder opens+seeks -- the flash. The flag is
						// consumed; later frames decode on the worker.
						slot.prime_from_warm = false
						decoder_set_preview(&slot.dec, slot_pick, slot_base)
						if decode_clip_frame_sync(&slot.dec, slot.path, clip_frame, slot.buffer[:]) {
							slot.frontier = req
							slot.have_frontier = true
							slot.has_frame = true
							preview_frontier = req
							slot.tex_dirty = true
							changed = true
						}
					} else {
						// Foreground clip decodes on the async worker: the render
						// loop never blocks on its seek/decode, so scrubbing the top
						// layer stays fluid even on a slow keyframe seek. The worker
						// resolves its own proxy (preview path passed through); probe
						// mode waits for the decode so asserts are deterministic.
						async_post_request(slot.path, slot_pick, slot_base, clip_frame)
						if !async_live_mode {
							async_wait_idle()
						}
						if async_try_consume(slot.path, clip_frame, slot.buffer[:]) {
					slot.frontier = req
					slot.have_frontier = true
					slot.has_frame = true
					preview_frontier = req
					slot.tex_dirty = true
					changed = true
				} else if dragging_playhead {
					// Exact-consume missed because the frontier outran the
					// worker. While scrubbing show the newest decoded face
					// instead of the pre-drag one, but leave the frontier
					// untouched so release still requests the exact frame.
					if ok, _ := async_try_consume_latest(slot.path, clip_frame, slot.buffer[:]); ok {
						slot.has_frame = true
						preview_frontier = req
						slot.tex_dirty = true
						changed = true
					}
				} else if nered_trace {
						fmt.printf("[vf] async miss req=%d ph=%d frontier=%d\n", req, playhead.frame, preview_frontier)
					}
				}
			} else {
					decoder_set_preview(&slot.dec, slot_pick, slot_base)
					if decode_clip_frame_sync(&slot.dec, slot.path, clip_frame, slot.buffer[:]) {
						slot.frontier = req
						slot.have_frontier = true
						slot.has_frame = true
						preview_frontier = req
						slot.tex_dirty = true
						changed = true
					} else if nered_trace {
						fmt.printf("[vf] miss req=%d ph=%d frontier=%d\n", req, playhead.frame, preview_frontier)
					}
				}
			}
		}
	}
	for i := next_slot; i < MAX_PREVIEW_SLOTS; i += 1 {
		if preview_slots[i].in_use {
			clip_decoder_reset(&preview_slots[i].dec)
			preview_slots[i].in_use = false
		}
	}
	return changed
}

// invalidate_preview_slots drops every preview slot's decoder, RAM cache,
// buffer and has_frame state so the next update_preview_slots re-derives it
// entirely from the current timeline.
//
// MUST be called after ANY model edit that removes clips (ripple delete, raw
// delete) or otherwise invalidates clip identity. Slots hold decoded pixels and
// an open decoder per clip_id; if you delete a clip and do NOT invalidate, the
// slot keeps the removed clip's decoded frames + GPU texture alive as a second
// state that can fight (and show) the removed clip at the playhead. This is the
// other half of the "deleted clip keeps rendering" bug — the timeline and audio
// drop the clip, but the preview slot must drop it too, explicitly.
	invalidate_preview_slots :: proc() {
	// The warm decoder targets a clip that no longer exists; drop it so a
	// stale hand-in can never occur.
	if warm_valid {
		clip_decoder_reset(&warm_decoder)
		warm_valid = false
		warm_clip_id = 0
	}
	for i in 0 ..< MAX_PREVIEW_SLOTS {
		slot := &preview_slots[i]
		if slot.in_use {
			clip_decoder_reset(&slot.dec)
			if slot.is_text && slot.texture != nil {
				queue_text_texture_release(slot.texture)
			}
			if slot.text_buf != nil {
				delete(slot.text_buf)
				slot.text_buf = nil
			}
			if slot.text_base_buf != nil {
				delete(slot.text_base_buf)
				slot.text_base_buf = nil
			}
			if slot.text_scratch != nil {
				delete(slot.text_scratch)
				slot.text_scratch = nil
			}
			slot^ = {}
		}
	}
}

// update_subtitle_slot refreshes a Subtitle generator clip's preview slot: it
// resolves the cue active at the clip-relative playhead, re-rasterizes the
// active cue's text (multi-line) when it changes (or the baked font changes),
// and re-centers the text box on the anchor (the previous box's center, or the
// canvas center on the clip's first rendered cue). Between cues the slot shows
// nothing. Returns true when the texture changed (caller re-uploads).
//
// Called on the UI thread only (mutates clip.transform/source_w/h to re-center
// the box exactly the way the text clip path re-measures on rename).
update_subtitle_slot :: proc(slot: ^Preview_Slot, clip: ^Clip, frame: i64) -> bool {
	changed := false
	src := srt_source(clip.srt_id)
	rel := frame - clip.timeline_start_frame
	srt_f := rel + clip.source_start_frame
	fps := f32(timeline_fps())
	active_text := ""
	active_hash: u64 = 0
	if src != nil {
		if ci := srt_cue_lookup(src.cues[:], srt_f, fps); ci >= 0 {
			active_text = src.cues[ci].text
			active_hash = text_clip_hash(active_text)
		}
	}
	// Any cue change (including dropping back into a gap) invalidates the
	// raster; a gap is just "empty cue". Identical back-to-back cues (same
	// hash) reuse the cached raster.
	cue_changed := slot.text_hash != active_hash
	slot.text_hash = active_hash

	if active_hash == 0 {
		// Between cues (or trimmed past the content): nothing to show.
		if cue_changed {
			slot.has_frame = false
			slot.text_w = 0
			slot.text_h = 0
			slot.tex_dirty = true
			changed = true
		}
		return changed
	}

	font_px := f32(TEXT_CLIP_FONT_PIXELS) * clip.scale
	if cue_changed || slot.text_font_px != font_px {
		// Split the cue text into lines once and reuse for both the base
		// measure and the baked raster.
		lines := strings.split(active_text, "\n")
		defer delete(lines)

		// Base measure at font 48: tight ink dims, and the new box dims for the
		// re-center. The transform is a TOP-LEFT anchor, so centering on the
		// anchor means transform = anchor_center - box/2.
		base_bw, base_bh := text_buf_size_for_lines(lines, TEXT_CLIP_FONT_PIXELS)
		need_base := base_bw * base_bh * 4
		if need_base > len(slot.text_base_buf) {
			delete(slot.text_base_buf)
			slot.text_base_buf = make([]u8, need_base)
		}
		if len(slot.text_scratch) < text_scratch_size_for(TEXT_CLIP_FONT_PIXELS) {
			delete(slot.text_scratch)
			slot.text_scratch = make([]u8, text_scratch_size_for(TEXT_CLIP_FONT_PIXELS))
		}
		_, _, bw0, bh0 := rasterize_lines_into_buffer(lines, slot.text_base_buf, base_bw, base_bh, &text_clip_font, &text_clip_font_init, slot.text_scratch, TEXT_CLIP_FONT_PIXELS)

		// Project-space box size for source_w x source_h text pixels at scale (1
		// source px maps to scale * PW/PREVIEW_W project px, uniform in both
		// axes — clip_image_bounds uses the same mapping).
		k := f32(project.width) / f32(PREVIEW_W)
		old_w := f32(clip.source_w) * clip.scale * k
		old_h := f32(clip.source_h) * clip.scale * k
		had_box := clip.source_w > 0 && clip.source_h > 0 && old_w > 0 && old_h > 0
		new_w := f32(bw0) * clip.scale * k
		new_h := f32(bh0) * clip.scale * k
		if new_w <= 1 || new_h <= 1 {
			// No measurable ink (empty/whitespace-only cue text).
			slot.has_frame = false
			slot.text_w = 0
			slot.text_h = 0
			slot.tex_dirty = true
			return true
		}
		if had_box {
			// Re-center on the previous box's center (the user's anchor).
			cx := clip.transform_x + old_w / 2
			cy := clip.transform_y + old_h / 2
			clip.transform_x = cx - new_w / 2
			clip.transform_y = cy - new_h / 2
		} else {
			// First rendered cue: anchor at the canvas center.
			clip.transform_x = f32(project.width) / 2 - new_w / 2
			clip.transform_y = f32(project.height) / 2 - new_h / 2
		}
		clip.source_w = c.int(bw0)
		clip.source_h = c.int(bh0)
		slot.source_w = c.int(bw0)
		slot.source_h = c.int(bh0)

		// Re-render at the baked font (48*scale) for the texture.
		slot.text_font_px = font_px
		need_sc := text_scratch_size_for(font_px)
		if need_sc > len(slot.text_scratch) {
			delete(slot.text_scratch)
			slot.text_scratch = make([]u8, need_sc)
		}
		bw, bh := text_buf_size_for_lines(lines, font_px)
		need := bw * bh * 4
		if need > len(slot.text_buf) {
			delete(slot.text_buf)
			slot.text_buf = make([]u8, need)
		}
		tx, ty, tw, th := rasterize_lines_into_buffer(lines, slot.text_buf, bw, bh, &text_clip_font, &text_clip_font_init, slot.text_scratch, font_px)
		slot.text_x = tx
		slot.text_y = ty
		slot.text_w = tw
		slot.text_h = th
		slot.text_tex_w = c.int(bw)
		slot.text_tex_h = c.int(bh)
		slot.has_frame = tw > 0 && th > 0
		slot.tex_dirty = true
		slot.text_recreate = true
		changed = true
	}

	// The box may have been re-centered; keep slot transform in sync.
	slot.transform_x = clip.transform_x
	slot.transform_y = clip.transform_y
	slot.scale = clip.scale
	return changed
}

// find_preview_slot returns the slot and Clip* for a given clip identity, or
// (nil, nil, false). Keyed on clip_id: asset_id+timeline_start_frame is NOT
// a valid key for a caller that holds it across more than one frame (e.g.
// tracking a clip through a drag) since timeline_start_frame is exactly the
// field a drag mutates every frame -- the old two-field key would stop
// matching the instant the clip moved, silently returning not-found mid-drag.
find_preview_slot :: proc(clip_id: u64) -> (^Preview_Slot, ^Clip, bool) {
	for i := 0; i < len(timeline.tracks); i += 1 {
		track := &timeline.tracks[i]
		for j := 0; j < len(track.clips); j += 1 {
			clip := &track.clips[j]
			if clip.clip_id == clip_id {
				for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
					if preview_slots[s].in_use && preview_slots[s].clip_id == clip_id {
						return &preview_slots[s], clip, true
					}
				}
			}
		}
	}
	return nil, nil, false
}
