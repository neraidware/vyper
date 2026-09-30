package main

import "core:c"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:strings"

// ---------------------------------------------------------------------------
// Preview slot lifecycle: assigning a Preview_Slot to each video clip that
// covers the playhead, driving decode, and looking slots up by clip identity.
// ---------------------------------------------------------------------------

// WARM_LOOKAHEAD is how many frames before the end of the current front clip
// the prewarm kicks in (in timeline frames). At 60fps, 120 frames = 2s.
WARM_LOOKAHEAD :: 120

// Warm_State is the preview prewarm cache: the decoder that pre-opens the clip
// which will play next (the one starting flush at -- or first after -- the
// current front video clip's end) and pre-decodes its first few frames while
// the current clip is still playing. When the playhead crosses the boundary,
// update_preview_slots hands this warm decoder to the slot so the transition is
// a cache hit instead of a cold reopen + keyframe-to-target seek that stalls
// the render loop exactly at the cut. The cold seek itself is absorbed earlier,
// during the tail of the current clip, where the dropped-frame preview
// tolerates a skip.
Warm_State :: struct {
	decoder: Clip_Decoder,
	buf:     [PREVIEW_W * PREVIEW_H * 4]u8,
	// clip_id is the clip the decoder/buf were warmed for; 0 = none.
	clip_id: u64,
	valid:   bool,
}
warm: Warm_State

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
	if !playhead.playing || playback.dir != 1 {
		return
	}
	// The single handoff decoder can warm only ONE upcoming clip per call.
	// Pick the clip that will next need a fresh, non-trivial claim -- the one
	// earliest to start within WARM_LOOKAHEAD across ALL tracks. The old code
	// only looked at each active clip's same-track successor and ABORTED the
	// whole scan on `return`s, so a clip starting fresh on a track where
	// nothing currently covers the playhead (a still landing on a cut -- its
	// left edge flush with the split boundary) was invisible until the playhead
	// was already inside it, cold-claiming and blanking for the decode
	// round-trip. That was the still flash.
	best: ^Clip
	best_start := max(i64)
	for t := 0; t < len(timeline.tracks); t += 1 {
		track := &timeline.tracks[t]
		active: ^Clip
		for i := 0; i < len(track.clips); i += 1 {
			c := &track.clips[i]
			if c.kind != .Video || c.path == nil {
				continue
			}
			if clip_visible_at(playhead.frame, c.timeline_start_frame, c.source_length_frames) {
				active = c
				break
			}
		}
		// Look for the next clip to consider: the successor of the active clip
		// (if flush/gap), or the first clip at/after the playhead when nothing
		// covers it yet (a still landing on a cut). Anchoring the search at the
		// active clip's END rather than the playhead keeps the flush-boundary
		// predecessor check below honest -- searching from the playhead would
		// return the active clip itself when the playhead sits exactly on.
		at_or_after := playhead.frame
		if active != nil {
			at_or_after = active.timeline_start_frame + active.source_length_frames
		}
		next := next_clip_on_track(track, 0, at_or_after)
		if next == nil {
			continue
		}
		if next.timeline_start_frame > playhead.frame + WARM_LOOKAHEAD {
			continue
		}
		// Flush same-asset boundary (split halves, duplicated clips): the slot's
		// decoder-preserve path (update_preview_slots) already turns a clip
		// covering the playhead RIGHT NOW into a single cheap forward decode, so
		// a pre-open here would be wasted work (an extra open + keyframe seek
		// into the file during the current clip's tail). Only pre-warm when the
		// boundary is a source-index gap, a cross-asset leap, or a fresh start
		// with no live predecessor -- the cases that would otherwise cold-seek.
		if active != nil &&
		   next.timeline_start_frame == active.timeline_start_frame + active.source_length_frames &&
		   next.path == active.path &&
		   next.source_start_frame == active.source_start_frame + active.source_length_frames {
			continue
		}
		if next.timeline_start_frame < best_start {
			best_start = next.timeline_start_frame
			best = next
		}
	}
	if best == nil {
		return
	}
	if warm.valid && warm.clip_id == best.clip_id {
		// Target unchanged; nothing new to decode (cached frames persist).
		return
	}
	if warm.valid {
		clip_decoder_reset(&warm.decoder)
		warm.valid = false
	}
	warm_proxy_buf: [4096]u8
	// Resolve the preview target PER FRAME (segmented proxies grow as the
	// background builder lands more segments); each decoded warm frame may come
	// from a different segment than the last, and the decoder reopens when the
	// physical file changes.
	//
	// prefer_source follows the same S5 gate as the front slot: once the warm
	// decoder is hw-backed, cache the ORIGINAL so the primed slot never
	// degrades to the proxy mid-transition. N/A for clips outside the media
	// bin (path has no asset entry -> false).
	warm_asset := find_asset(best.asset_id)
	warm_pick, warm_base := proxy_pick_for_frame(
		best.path,
		best.source_length_frames,
		best.source_start_frame,
		warm_proxy_buf[:],
		warm_asset != nil && asset_source_hw(warm_asset),
	)
	decoder_set_preview(&warm.decoder, warm_pick, warm_base)
	if !decode_clip_frame_sync(
		&warm.decoder,
		best.path,
		best.source_start_frame,
		warm.buf[:],
	) {
		return
	}
	// Buttress the cache with a few following frames (cheap forward steps). A
	// still image has no following frames to decode -- its single frame was
	// just decoded, and that one frame is the whole clip.
	if best.is_still {
		warm.clip_id = best.clip_id
		warm.valid = true
		return
	}
	for kf in i64(1) ..< 4 {
		wf := best.source_start_frame + kf
		warm_pick, warm_base = proxy_pick_for_frame(
			best.path,
			best.source_length_frames,
			wf,
			warm_proxy_buf[:],
			warm_asset != nil && asset_source_hw(warm_asset),
		)
		decoder_set_preview(&warm.decoder, warm_pick, warm_base)
		if !decode_clip_frame_sync(&warm.decoder, best.path, wf, warm.buf[:]) {
			break
		}
	}
	warm.clip_id = best.clip_id
	warm.valid = true
}

// slot_claim_flush_peer finds the slot a NEWLY-covering video clip should
// inherit: the in_use slot of a flush same-asset neighbor that just left the
// playhead this frame. A split produces two halves of one source, adjacent
// (half_end == other_start) and source-contiguous; when the playhead crosses
// the cut, the departing half's slot is STILL in_use (swept only at the end of
// update_preview_slots), so the entering half would otherwise cold-claim a
// fresh slot -- reset+reopen+keyframe-seek, blanking has_frame for the whole
// async round-trip: the split flash. Claiming the partner's slot instead makes
// the reassignment block's same_asset path fire (slot.dec preserved) and lets
// this slot's async worker -- already open on the same file at the frame just
// before the cut -- serve the entering half's first frame instantly.
//
// Direction-agnostic: covers the playhead moving forward (entering clip starts
// where the departing clip ends) and reverse (entering clip ends where the
// departing clip starts), so scrubbing back and forth across a cut inherits
// the partner's slot every time, never cold-claiming.
slot_claim_flush_peer :: proc(clip: ^Clip, claimed: [MAX_PREVIEW_SLOTS]bool) -> int {
	if clip == nil || clip.path == nil || clip.kind != .Video {
		return -1
	}
	for s in 0 ..< MAX_PREVIEW_SLOTS {
		slot := &preview_slots[s]
		if !slot.in_use || claimed[s] {
			continue
		}
		if slot.path == nil || slot.path != clip.path {
			continue
		}
		peer := slot_clip_with_id(slot.clip_id)
		if peer == nil || peer.kind != .Video || peer.is_still || peer.path != clip.path {
			continue
		}
		peer_end := peer.timeline_start_frame + peer.source_length_frames
		peer_src_end := peer.source_start_frame + peer.source_length_frames
		clip_end := clip.timeline_start_frame + clip.source_length_frames
		clip_src_end := clip.source_start_frame + clip.source_length_frames
		forward :=
			peer_end == clip.timeline_start_frame &&
			peer_src_end == clip.source_start_frame
		reverse :=
			clip_end == peer.timeline_start_frame &&
			clip_src_end == peer.source_start_frame
		if !forward && !reverse {
			continue
		}
		// The peer must be on the OTHER side of the playhead's frame -- if it
		// still covers the playhead it is a live clip, not a departing half.
		frame := playhead.frame
		if clip_visible_at(frame, peer.timeline_start_frame, peer.source_length_frames) {
			continue
		}
		return s
	}
	return -1
}

// pick_hash_u32 fingerprints a proxy pick path (a cstring resolving to a
// segment file, the source, or nil when preview proxy is disabled) so the
// idle-skip in update_preview_slots can tell "same frame, better file".
pick_hash_u32 :: proc(pick: cstring) -> u32 {
	if pick == nil || len(pick) == 0 {
		return 0
	}
	return hash.fnv32(transmute([]u8)string(pick))
}

// update_preview_slots walks every video clip covering the current playhead and
// ensures each has a Preview_Slot with its frame decoded (using the slot's RAM
// frame cache). Slots are reassigned by index each frame; when a slot's clip
// identity changes its decoder is reset and reopened. Returns true if any
// frame changed (caller re-uploads textures).
update_preview_slots :: proc() -> bool {
	spall_scope(#procedure)
	changed := false
	// Identity-stable slots: each covering clip keeps the slot it already owns
	// (its decoder + RAM cache + last decoded face), so a composition change
	// mid-playback -- a text clip joining the playhead above a video -- reuses
	// the video's existing slot instead of reshuffling slot indexes and
	// re-opening its decoder (which blanked has_frame and flashed the canvas
	// black while the async reopen+seek landed). A clip first claims a free
	// slot; dropped clips are swept at the end. Depth order comes from `layer`
	// (the track-order walk position), NOT the slot index.
	claimed: [MAX_PREVIEW_SLOTS]bool
	layer: u8
	if active_interaction == .Playhead_Scrub {
		playback.scrub_tick += 1
	}
	// Warm the upcoming clip's decoder before the playhead crosses the
	// boundary, so the transition hands over a warm decoder (no cut stall).
	prewarm_next_clip()
	sync_track_order()
	for w := 0; w < len(timeline.track_order); w += 1 {
		ti := timeline.track_order[w]
		track := &timeline.tracks[ti]
		for i := 0; i < len(track.clips); i += 1 {
			clip := &track.clips[i]
			if clip.kind != .Video && clip.kind != .Text {
				continue
			}
			frame := playhead.frame
			if !clip_visible_at(frame, clip.timeline_start_frame, clip.source_length_frames) {
				continue
			}
			slot_idx := -1
			for s in 0 ..< MAX_PREVIEW_SLOTS {
				if preview_slots[s].in_use && preview_slots[s].clip_id == clip.clip_id {
					slot_idx = s
					break
				}
			}
			if slot_idx < 0 {
				// Fresh clip at a flush same-asset boundary (split halves,
				// duplicates): claim the departing partner's still-in_use slot
				// instead of a free slot. The partner half just left the playhead
				// THIS frame -- it's on the other side of the cut -- so its slot
				// is still in_use (the sweep runs after the walk, line 724).
				// Claiming it lets the reassignment block's same_asset path fire:
				// the decoder stays open and both the RAM cache and this slot's
				// async worker are positioned one frame back from the cut, so the
				// entering half advances one frame instead of cold-reopening and
				// keyframe-seeking (which blanked has_frame -- the split flash).
				// Without this, both halves cold-claim at EVERY crossing of the
				// cut: the split flash -- forward pass blanks the entering half,
				// and scrubbing back across it blanks the OTHER half.
				slot_idx = slot_claim_flush_peer(clip, claimed)
			}
			if slot_idx < 0 {
				// Genuinely fresh clip: claim the lowest free slot. Its decoder
				// is reset by the reassignment block below; the texture behind
				// that index is the renderer's shared per-index preview texture.
				for s in 0 ..< MAX_PREVIEW_SLOTS {
					if !preview_slots[s].in_use {
						slot_idx = s
						break
					}
				}
			}
			if slot_idx < 0 {
				// All slots busy; the clip can't be shown this frame. Bounded
				// preview: keep walking so later (usually under) clips still
				// claim what's free.
				continue
			}
			claimed[slot_idx] = true
			layer += 1
			slot := &preview_slots[slot_idx]
			slot.layer = layer
			// Assigned every claimed frame, next to `layer`, so a slot reassigned
			// from a subtitle clip to a video (or the reverse) cannot keep a stale
			// pinning flag.
			slot.is_subtitle = clip.kind == .Text && clip.generator == .Subtitles
			fresh_claim := !slot.in_use || slot.clip_id != clip.clip_id
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
				warm_hit := warm.valid && warm.clip_id == clip.clip_id
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
				flash_rec_note_kill(slot_idx, "reassign-to-other-clip")
				slot^ = {}
				if same_asset {
					slot.dec = saved_dec
				} else if warm_hit {
					slot.dec = warm.decoder
					warm.decoder = {}
					warm.valid = false
					warm.clip_id = 0
				}
				if warm_hit {
					slot.prime_sync = true
				} else if same_asset {
					// Same-asset flush (split halves/duplicates): the preserved
					// decoder is positioned one frame back from the cut, so the
					// entering half's first frame is a single forward step. Prime
					// it synchronously like a warm handoff -- otherwise the async
					// worker serves its PREVIOUS completed decode (the OUTGOING
					// half's boundary frame, matched on path alone, rejected by the
					// window check below) and the slot holds a blank while the
					// worker re-seeks: the black flash.
					slot.prime_sync = true
				}
				slot.in_use = true
				slot.clip_id = clip.clip_id
				slot.asset_id = clip.asset_id
				slot.path = clip.path
				slot.tex_dirty = true
				if vyper_trace {
					fmt.printf(
						"[vf] assign slot=%d asset=%d tl=%d src=%d len=%d playing=%v same_asset=%v warm_hit=%v clip_id=%d warm_id=%d\n",
						slot_idx,
						clip.asset_id,
						clip.timeline_start_frame,
						clip.source_start_frame,
						clip.source_length_frames,
						playhead.playing,
						same_asset,
						warm_hit,
						clip.clip_id,
						warm.clip_id,
					)
				}
				mem.zero(raw_data(slot.buffer[:]), len(slot.buffer))
				// The reassign zeroed the slot (slot^ = {}), wiping the layer the
				// walk just assigned; restore it so this update draws the slot at
				// its real stack depth instead of layer 0 (the transient the
				// pre-fix recorder logged).
				slot.layer = layer
			}
			// A position/source shift invalidates the slot's decoded buffer; it
			// is cleared below and the exact playhead frame requested next update
			// (the source-frame cache makes the re-decode cheap).
			anchor_shifted :=
				slot.timeline_start_frame != clip.timeline_start_frame ||
				slot.source_start_frame != clip.source_start_frame
			if vyper_trace && anchor_shifted {
				fmt.printf(
					"[vf] SHIFT asset=%d tl=%d->%d src=%d->%d playing=%v\n",
					clip.asset_id,
					slot.timeline_start_frame,
					clip.timeline_start_frame,
					slot.source_start_frame,
					clip.source_start_frame,
					playhead.playing,
				)
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
				//
				// EXCEPT while the clip is the one under the cursor right now:
				// a live drag mutates timeline_start_frame every mousemove, so
				// blanking would flash the canvas black between every move and
				// the fresh decode (the front slot's decode runs on the async
				// worker, adding a round-trip per move). Keep the last decoded
				// face on screen through the drag; the decode below chases the
				// clip's new position (the idle-skip misses because the
				// requested clip_frame changed).
				if clip_move.clip == clip || active_interaction == .Clip_Resize {
					// Leave has_frame as-is: paint the stale face through the
					// drag (the decode below chases the clip's new position).
				} else if fresh_claim {
					// Fresh claim, no stale pixels to clear: the slot was just
					// zeroed (or taken from another clip) this update. The
					// anchor-shift blank below exists to clear a persisting
					// slot's stale frame when ITS clip moved; skipping it here
					// is required or a warm decoder handed off by prewarm (for
					// exactly this clip, keeping its buffer) is wiped by the
					// 0 != clip.start anchor compare before prime_sync can
					// serve it -- the still flash at a freshly-covering clip.
				} else {
					flash_rec_note_kill(slot_idx, "anchor-shift")
					slot.has_frame = false
					slot.tex_dirty = false
					mem.zero(raw_data(slot.buffer[:]), len(slot.buffer))
				}
			}
		// Keyframe wiring (Active 3 follow-up): a clip's keyed properties are
		// evaluated at the playhead and taken into the slot in place of the
		// clip's resting transform, so animating rows move on the canvas
		// live (and the clip's own fields keep their resting base value).
		// kf_geom_sample_lane returns the caller base when the property has no
		// track (or the playhead sits before its first key), so un-keyed
		// clips render their exact current values; it also resolves a lane
		// whose section currently lives in packed form.
		slot.transform_x, _ = kf_geom_sample_lane(clip, "transform.x", frame, clip.transform_x)
		slot.transform_y, _ = kf_geom_sample_lane(clip, "transform.y", frame, clip.transform_y)
		slot.scale, _ = kf_geom_sample_lane(clip, "scale", frame, clip.scale)
		slot.crop_l, _ = kf_geom_sample_lane(clip, "crop.l", frame, clip.crop_l)
		slot.crop_r, _ = kf_geom_sample_lane(clip, "crop.r", frame, clip.crop_r)
		slot.crop_t, _ = kf_geom_sample_lane(clip, "crop.t", frame, clip.crop_t)
		slot.crop_b, _ = kf_geom_sample_lane(clip, "crop.b", frame, clip.crop_b)
		slot.opacity, _ = kf_geom_sample_lane(clip, "opacity", frame, clip.opacity)
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
				// slot.scale, not clip.scale: this is the raster RESOLUTION the box
				// is measured against, so taking the resting value would bake glyphs
				// at the base scale and then stretch them by the sampled one on a
				// clip whose scale is keyed — visibly soft, and re-baked only when
				// the title changes. The two have to come from the same frame or the
				// raster and the box it fills disagree about what scale means.
				font_px := f32(TEXT_CLIP_FONT_PIXELS) * slot.scale
				// The box is ink WIDTH x metric BOX HEIGHT: width is the tight
				// ink (single line, so it hugs the text); height is the font's
				// typographic line box at 48 (ascent + descent + TEXT_BOX_PAD
				// air), constant per font/size, so it always covers descenders
				// and does NOT jump when the title's deepest glyph changes (the
				// old tight-ink height did).
				base_bw, base_bh := text_buf_size_for(
					clip.name,
					&text_clip_state.font,
					&text_clip_state.font_init,
					TEXT_CLIP_FONT_PIXELS,
				)
				if base_changed {
					// Re-measure / re-derive the base dims at font 48 on rename.
					need_base := base_bw * base_bh * 4
					base_buf := text_buf_ensure(&slot.text_base_buf, need_base)
					scratch := text_buf_ensure(&slot.text_scratch, text_scratch_size_for(TEXT_CLIP_FONT_PIXELS))
					_, _, bw0, _ := rasterize_title_into_buffer(
						clip.name,
						base_buf,
						base_bw,
						base_bh,
						&text_clip_state.font,
						&text_clip_state.font_init,
						scratch,
						TEXT_CLIP_FONT_PIXELS,
					)
					// Legacy clips (pre-metric model) carry a galley-height
					// source_h; the box is deterministic from the name alone, so
					// a mismatch means "remodel on load, once".
					if bw0 > 0 {
						clip.source_w = c.int(bw0)
						clip.source_h = c.int(base_bh)
						slot.source_w = c.int(bw0)
						slot.source_h = c.int(base_bh)
					}
					slot.text_hash = name_hash
				}
				stale_box :=
					base_changed == false && clip.source_w > 0 && clip.source_h != c.int(base_bh)
				if stale_box {
					clip.source_h = c.int(base_bh)
					slot.source_h = c.int(base_bh)
				}
				if base_changed || stale_box || slot.text_font_px != font_px {
					// Re-render at the baked font (48*scale) for the texture.
					slot.text_font_px = font_px
					scratch := text_buf_ensure(&slot.text_scratch, text_scratch_size_for(font_px))
					bw, bh := text_buf_size_for(
						clip.name,
						&text_clip_state.font,
						&text_clip_state.font_init,
						font_px,
					)
					need := bw * bh * 4
					tex_buf := text_buf_ensure(&slot.text_buf, need)
					ink_x, _, ink_bw, _ := rasterize_title_into_buffer(
						clip.name,
						tex_buf,
						bw,
						bh,
						&text_clip_state.font,
						&text_clip_state.font_init,
						scratch,
						font_px,
					)
					// Sample the tight ink horizontally (the width estimate is
					// over-wide) over the FULL metric box height, so the quad
					// (source_w x source_h) maps 1:1 onto the texture with
					// TEXT_BOX_PAD air above and descent space below the ink.
					slot.text_x = ink_x
					slot.text_y = 0
					slot.text_w = ink_bw
					slot.text_h = bh
					// The texture is the FULL buffer (bw x bh), so the upload +
					// UV sampling work against it.
					slot.text_tex_w = c.int(bw)
					slot.text_tex_h = c.int(bh)
					slot.has_frame = ink_bw > 0
					slot.tex_dirty = true
					slot.text_recreate = true
					changed = true
				}
				if !slot.has_frame || slot.text_w <= 0 || slot.text_h <= 0 {
					continue
				}
				continue
			}
			// Playback is dropped-frame: request the current playhead frame and
			// display whatever is most-recently decoded (real speed, stutter when
			// slow, never slow-motion, never frozen). When paused, exact frames
			// are requested for scrubbing. There is no per-slot frontier
			// bookkeeping: the playhead frame is always the target, so a clip
			// move/switch or a scrub naturally requests the exact current frame
			// with no stale crawl state to invalidate.
			req := frame
			// Scrub throttle: a drag fires many mousemoves, which would otherwise
			// force an exact-seek decode per UI frame per slot. Decimate: decode
			// exact frames on every SCRUB_DECIMATION-th update only, showing the
			// last decoded face between. EVERY slot is exempt now that every
			// slot decodes on its own async worker (async_decoders[slot_idx]):
			// that path is non-blocking, so it chases the pointer every update
			// and scrubbing every layer -- not just the top one -- stays live.
			// A slot without a worker (e.g. a probe that never called
			// async_dec_init) falls back to the old throttled/synchronous
			// behavior. A slot that has not yet covered its current frame still
			// decodes on the first throttled tick so a clip crossing the playhead
			// mid-drag shows immediately.
			scrub_skip :=
				active_interaction == .Playhead_Scrub &&
				playback.scrub_tick % SCRUB_DECIMATION != 0 &&
				!async_has_worker(slot_idx)
			clip_frame := clip.source_start_frame + req - clip.timeline_start_frame
			if clip.is_still {
				// A still has one source frame: hold it for the whole clip span.
				clip_frame = clip.source_start_frame
			}
			// Resolve the preview target PER FRAME: a segmented proxy grows as
			// the background builder lands more segments, so the frame the
			// decoder serves may switch files (segment N -> source, or N -> N+1)
			// as the playhead crosses a segment boundary mid-build. The decoder
			// reopens on the physical-file change; render/probe paths are
			// unaffected because they never set a preview target.
			//
			// S5 original-rate: during steady forward playback a hw-backed
			// decoder serves the ORIGINAL source (full quality at source fps,
			// deadline: a CPU core of air left on 1080p60); every other mode
			// -- scrub, pause, reverse, sw decode -- keeps the gop=1 proxy so
			// arbitrary seeks stay instant. Whether the physical decoder would
			// be hw-backed is a property of the SOURCE FILE on this machine,
			// latched per asset (asset_source_hw) -- never of whichever file
			// the slot decoder happens to hold right now. A gate reading the
			// currently-open file's hw state is self-referential: picking the
			// source opens it, its hw_pix_fmt flips the gate, which reopens the
			// proxy, whose hw_pix_fmt flips it back -- two full decoder
			// reopens per frame on machines where source and proxy differ in
			// hw support (source sw + proxy vaapi = the user's stutter). The
			// latch stays put until the asset changes. Clips outside the media
			// bin (no asset entry) fall back to the proxy.
			prefer_source := false
			if playhead.playing && playback.dir == 1 {
				asset := find_asset(clip.asset_id)
				prefer_source = asset != nil && asset_source_hw(asset)
			}
			pick_buf: [4096]u8
			slot_pick, slot_base := proxy_pick_for_frame(
				clip.path,
				clip.source_length_frames,
				clip_frame,
				pick_buf[:],
				prefer_source,
			)
			// Idle-skip: when the playhead is parked and this slot already
			// shows the exact frame decoded through the exact same proxy file
			// the pick just resolved to, the screen is already correct — skip
			// the decode + upload (a ~4MB GPU transfer per slot). The pick
			// comparison matters: the background builder keeps landing new
			// segments, so the SAME source frame may later resolve to a better
			// file (source -> segment); that must re-decode even while parked.
			pick_hash := pick_hash_u32(slot_pick)
			if slot.has_frame &&
			   !slot.tex_dirty &&
			   slot.displayed_frame == clip_frame &&
			   slot.displayed_pick == pick_hash {
				continue
			}
			if !scrub_skip || !slot.has_frame {
				if async_has_worker(slot_idx) {
					if slot.prime_sync {
						// Transition frame: the decoder handed over (warm cache or
						// same-asset flush) already holds this clip's first frames
						// adjacent to the decode target, so serve this one
						// synchronously (a cache hit or single forward step) and
						// set has_frame immediately. Posting to the worker here
						// would leave the freshly-reassigned slot dark (or — on the
						// flush boundary, before the worker re-seeks — consuming the
						// outgoing half's stale same-path result: the wrong-side
						// flash) while its cold decoder opens+seeks. The flag is
						// consumed; later frames decode on the worker.
						slot.prime_sync = false
						decoder_set_preview(&slot.dec, slot_pick, slot_base)
						if decode_clip_frame_sync(
							&slot.dec,
							slot.path,
							clip_frame,
							slot.buffer[:],
						) {
							slot.displayed_frame = clip_frame
							slot.displayed_pick = pick_hash
							slot.has_frame = true
							slot.tex_dirty = true
							changed = true
						}
					} else {
						// Every slot decodes on its OWN async worker
						// (async_decoders[slot_idx]): the render loop never
						// blocks on any slot's seek/decode, so an edit that
						// shifts several clips at once (a ripple cut) can no
						// longer stall this thread -- and with it
						// playback_update/audio_update, which run right after
						// update_preview_slots on the same thread (see
						// main.odin). Each worker resolves its own proxy
						// (preview path passed through); probe mode waits so
						// asserts are deterministic.
						//
						// Consume the worker's NEWEST completed decode, not an
						// exact frame match: an exact-only consume succeeds only
						// when the playhead sits still, so once a worker lags
						// even one tick behind moving playback that slot's
						// preview freezes until pause. Consuming the newest
						// keeps a freshly-decoded face on screen every update
						// (dropped-frame preview) regardless of how far behind
						// the worker falls; each worker selects the newest
						// request posted to IT, so it converges toward the
						// playhead on its own, independently per slot.
						async_post_request(slot_idx, slot.path, slot_pick, slot_base, clip_frame)
						if !async_live_mode {
							async_wait_idle(slot_idx)
						}
						// The worker serves the newest COMPLETED decode, which lags
						// the requested frame during playback (dropped-frame). It
						// may have decoded through a DIFFERENT proxy segment than
						// the current playhead's pick (crossing a segment boundary
						// while behind). displayed_frame AND displayed_pick must
						// both describe the pixels actually served -- the worker
						// returns the pick hash it used for the frame it decoded,
						// never the current request's. Stamp both from the served
						// result so the idle-skip (same frame AND same file) stays
						// honest; otherwise the slot advertises a (frame,file)
						// identity that matches no real decode and the preview
						// re-decodes/serves the wrong thing across the boundary.
						//
						// The worker keys results by SOURCE PATH only, so its
						// "newest completed" can belong to the PRIOR clip identity
						// that shared this path -- a flush-boundary crossing keeps
						// the slot, and the worker's last completed decode is the
						// OUTGOING half's boundary frame, a frame outside the
						// entering clip's source window ([source_start,
						// source_start+len)). Consuming it would paint the wrong
						// side of the cut (the image flash); the synchronous prime
						// above covers the claiming update itself, but THIS update
						// (and any until the worker re-seeks) must reject the stale
						// result without copying it into slot.buffer -- a copy would
						// leave wrong pixels that the tex_dirty upload renders
						// anyway. So peek first, validate the window, then consume
						// only an in-window result and keep the primed/good frame
						// while the worker converges.
						in_window := false
						p_ok, p_frame, _ := async_peek_result(slot_idx, slot.path)
						if p_ok {
							in_window =
								p_frame >= clip.source_start_frame &&
								p_frame < clip.source_start_frame + clip.source_length_frames
						}
						if !in_window {
							if vyper_trace {
								fmt.printf(
									"[vf] stale-peek=%d clip(src=%d+%d) slot=%d ph=%d\n",
									p_frame,
									clip.source_start_frame,
									clip.source_length_frames,
									slot_idx,
									playhead.frame,
								)
							}
							continue
						}
						if ok, dyn_frame, served_pick := async_try_consume_latest(
							slot_idx,
							slot.path,
							clip_frame,
							slot.buffer[:],
						); ok {
							slot.displayed_frame = dyn_frame
							slot.displayed_pick = served_pick
							slot.has_frame = true
							slot.tex_dirty = true
							changed = true
						} else if vyper_trace {
							fmt.printf("[vf] async miss slot=%d req=%d ph=%d\n", slot_idx, req, playhead.frame)
						}
					}
				} else {
					// No worker for this slot (async subsystem not initialized --
					// some headless probes never call async_dec_init). Same
					// synchronous path as before; these probes don't exercise the
					// ripple-cut multi-slot scenario this fix targets.
					decoder_set_preview(&slot.dec, slot_pick, slot_base)
					if decode_clip_frame_sync(&slot.dec, slot.path, clip_frame, slot.buffer[:]) {
						slot.displayed_frame = clip_frame
						slot.displayed_pick = pick_hash
						slot.has_frame = true
						slot.tex_dirty = true
						changed = true
					} else if vyper_trace {
						fmt.printf("[vf] miss slot=%d req=%d ph=%d\n", slot_idx, req, playhead.frame)
					}
				}
			}
		}
	}
	for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
		if preview_slots[s].in_use && !claimed[s] {
			// The slot's clip no longer covers the playhead (clip ended, moved
			// away, or was deleted). Free the decoder + text-owned resources.
			// Video slots ride the renderer's shared per-index preview texture,
			// so nothing GPU-side is owned here; a text slot's tight texture is
			// released via the render loop's pending-release queue (no device
			// on this thread).
			slot := &preview_slots[s]
			flash_rec_note_kill(s, "sweep")
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
	if warm.valid {
		clip_decoder_reset(&warm.decoder)
		warm.valid = false
		warm.clip_id = 0
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
		// measure and the baked raster. Temp arena: event-driven (cue/font
		// change), and the frame's free_all reclaims it either way.
		lines := strings.split(active_text, "\n", context.temp_allocator)

		// Base measure at font 48. The box is ink WIDTH x metric BOX HEIGHT.
		// Width: the tight ink width (single-line cues hug their text, and
		// multi-line cues are centered on the widest line's ink). Height: the
		// SUM of each line's typographic line box (ascent + descent) plus
		// TEXT_BOX_PAD air -- a font-metric constant per line, so the height
		// cannot balloon with the galley estimate and a line always reserves
		// its own descent space. Anchoring the tight ink bottom would be wrong:
		// it tracks the deepest descender and drags the baseline up.
		base_bw, base_bh := text_buf_size_for_lines(
			lines,
			&text_clip_state.font,
			&text_clip_state.font_init,
			TEXT_CLIP_FONT_PIXELS,
		)
		need_base := base_bw * base_bh * 4
		base_buf := text_buf_ensure(&slot.text_base_buf, need_base)
		scratch := text_buf_ensure(&slot.text_scratch, text_scratch_size_for(TEXT_CLIP_FONT_PIXELS))
		_, _, ink_w, ink_h := rasterize_lines_into_buffer(
			lines,
			base_buf,
			base_bw,
			base_bh,
			&text_clip_state.font,
			&text_clip_state.font_init,
			scratch,
			TEXT_CLIP_FONT_PIXELS,
			context.temp_allocator,
		)

		// Project-space box size for source_w x source_h text pixels at scale (1
		// source px maps to scale * PW/PREVIEW_W project px, uniform in both
		// axes — clip_image_bounds uses the same mapping).
		k := f32(project.width) / f32(PREVIEW_W)
		old_w := f32(clip.source_w) * clip.scale * k
		old_h := f32(clip.source_h) * clip.scale * k
		had_box := clip.source_w > 0 && clip.source_h > 0 && old_w > 0 && old_h > 0
		new_w := f32(ink_w) * clip.scale * k
		new_h := f32(base_bh) * clip.scale * k
		if ink_w <= 1 || ink_h <= 1 {
			// No measurable ink (empty/whitespace-only cue text).
			slot.has_frame = false
			slot.text_w = 0
			slot.text_h = 0
			slot.tex_dirty = true
			return true
		}
		if had_box {
			// Re-anchor on the previous box: keep the box CENTER in x and the
			// box BOTTOM EDGE in y fixed. The bottom edge is the last line's
			// metric line box bottom (font-metric), so subtitles grow upward
			// around a stable baseline instead of floating as the cue's line
			// count changes.
			cx := clip.transform_x + old_w / 2
			bottom := clip.transform_y + old_h
			clip.transform_x = cx - new_w / 2
			clip.transform_y = bottom - new_h
		} else {
			// First rendered cue: anchor at the canvas center.
			clip.transform_x = f32(project.width) / 2 - new_w / 2
			clip.transform_y = f32(project.height) / 2 - new_h / 2
		}
		clip.source_w = c.int(ink_w)
		clip.source_h = c.int(base_bh) // metric line-box stack, text pixels
		slot.source_w = c.int(ink_w)
		slot.source_h = c.int(base_bh)

		// Re-render at the baked font (48*scale) for the texture.
		slot.text_font_px = font_px
		// The BAKED font's scratch and texture, distinct from the base
		// measurement ones above: the same two buffers, asked for a bigger size
		// (48*scale, not 48). Grow-only, so this supersedes rather than conflicts
		// with the earlier ensure.
		baked_scratch := text_buf_ensure(&slot.text_scratch, text_scratch_size_for(font_px))
		bw, bh := text_buf_size_for_lines(lines, &text_clip_state.font, &text_clip_state.font_init, font_px)
		baked_buf := text_buf_ensure(&slot.text_buf, bw * bh * 4)
		ink_x, _, ink_bw, _ := rasterize_lines_into_buffer(
			lines,
			baked_buf,
			bw,
			bh,
			&text_clip_state.font,
			&text_clip_state.font_init,
			baked_scratch,
			font_px,
			context.temp_allocator,
		)
		// Sample the ink horizontally (text sits at the left of the over-wide
		// galley estimate) over the FULL metric box height. The ink box is
		// source_w x source_h, so the sub-rect maps 1:1 onto the quad with the
		// text centered. Full-height sampling keeps the baseline on the last
		// line's metric box bottom (see above).
		slot.text_x = ink_x
		slot.text_y = 0
		slot.text_w = ink_bw
		slot.text_h = bh
		slot.text_tex_w = c.int(bw)
		slot.text_tex_h = c.int(bh)
		slot.has_frame = true
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
