package main

import "core:c"
import "core:fmt"
import "core:mem"

// ---------------------------------------------------------------------------
// Preview slot lifecycle: assigning a Preview_Slot to each video clip that
// covers the playhead, driving decode, and looking slots up by clip identity.
// ---------------------------------------------------------------------------

// update_preview_slots walks every video clip covering the current playhead and
// ensures each has a Preview_Slot with its frame decoded (using the slot's RAM
// frame cache). Slots are reassigned by index each frame; when a slot's clip
// identity changes its decoder is reset and reopened. Returns true if any
// frame changed (caller re-uploads textures).
update_preview_slots :: proc() -> bool {
	changed := false
	next_slot := 0
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
			next_slot += 1
			// Identity is the clip instance (clip_id), not its asset or its
			// position: asset_id alone would conflate two different clips of
			// the same source file, and timeline_start_frame changes under a
			// drag, which is exactly the identity a dragged clip needs to KEEP.
			// The decoder and its source-frame-keyed RAM cache stay intact
			// across a same-clip position change (a drag): the clip_frame
			// request below shifts with the new position and the cache still
			// serves it (adjacent frames) or the decoder seeks once.
			if !slot.in_use || slot.clip_id != clip.clip_id {
				if slot.in_use {
					clip_decoder_reset(&slot.dec)
				}
				slot^ = {}
				slot.in_use = true
				slot.clip_id = clip.clip_id
				slot.asset_id = clip.asset_id
				slot.path = clip.path
				slot.tex_dirty = true
				if nered_trace {
					fmt.printf("[vf] assign slot=%d asset=%d tl=%d src=%d len=%d playing=%v\n",
						next_slot - 1, clip.asset_id, clip.timeline_start_frame, clip.source_start_frame, clip.source_length_frames, playhead.playing)
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
				// The tight, top-left bounding box. The text bounds are kept in
				// TEXT pixels (buffer space), NOT project units: clip_image_bounds
				// maps them to screen with a single uniform scale so the title is
				// never squished by the project's aspect or resolution.
				slot.crop_l = 0
				slot.crop_r = 0
				slot.crop_t = 0
				slot.crop_b = 0
				if slot.text_hash != text_clip_hash(clip.name) {
					text_w, text_h := render_text_clip_into_buffer(clip.name, slot.buffer[:], PREVIEW_W, PREVIEW_H)
					slot.text_hash = text_clip_hash(clip.name)
					slot.text_w = text_w
					slot.text_h = text_h
					clip.source_w = c.int(text_w)
					clip.source_h = c.int(text_h)
					slot.source_w = c.int(text_w)
					slot.source_h = c.int(text_h)
					slot.has_frame = text_w > 0 && text_h > 0
					slot.tex_dirty = true
					changed = true
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
					req = slot.frontier + 1
				}
			}
			clip_frame := clip.source_start_frame + req - clip.timeline_start_frame
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
	for i in 0 ..< MAX_PREVIEW_SLOTS {
		slot := &preview_slots[i]
		if slot.in_use {
			clip_decoder_reset(&slot.dec)
			slot^ = {}
		}
	}
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
