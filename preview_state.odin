package main

import "core:fmt"

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
			if clip.kind != .Video {
				continue
			}
			frame := playhead.frame
			if frame < clip.timeline_start_frame || frame >= clip.timeline_start_frame + clip.source_length_frames {
				continue
			}
			slot := &preview_slots[next_slot]
			next_slot += 1
			// Identity is the underlying asset only: moving a clip along the
			// timeline changes its timeline_start_frame but not its pixels, so
			// the decoder and its source-frame-keyed RAM cache stay intact.
			// The clip_frame request below shifts with the new position and the
			// cache still serves it (adjacent frames) or the decoder seeks once.
			if !slot.in_use || slot.asset_id != clip.asset_id {
				if slot.in_use {
					clip_decoder_reset(&slot.dec)
				}
				slot^ = {}
				slot.in_use = true
				slot.asset_id = clip.asset_id
				slot.path = clip.path
				slot.tex_dirty = true
			}
			// A position/source shift makes the slot's frontier (timeline-keyed
			// forward splice point) invalid: if we keep it, a clip moved forward
			// gets clamped to req = frontier+1 which maps BELOW its new start.
			// Within EITHER mapping the exact-playhead frame shown is the right
			// one, so decode exactly once without the forward-drop clamp (the
			// source-frame cache still makes it cheap).
			anchor_shifted := slot.timeline_start_frame != clip.timeline_start_frame || slot.source_start_frame != clip.source_start_frame
			slot.timeline_start_frame = clip.timeline_start_frame
			slot.source_start_frame = clip.source_start_frame
			if anchor_shifted {
				slot.have_frontier = false
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
			// While playing, decode forward as fast as decode allows and show
			// whatever the newest decoded frame is (dropped-frame preview: real
			// speed, stutter when slow, never slow-motion). When paused, exact
			// frames are requested for scrubbing. The frontier is per-slot so
			// moving a clip to an earlier point (or switching clips) never gets
			// frozen on stale content: skip only when the playhead sits AHEAD of
			// this slot's own frontier, never behind it.
			req := frame
			if playhead.playing {
				if slot.have_frontier && req > slot.frontier + 1 {
					req = slot.frontier + 1
				}
			}
			clip_frame := clip.source_start_frame + req - clip.timeline_start_frame
			// if audio_trace {
			// 	fmt.printf("[vf] req=%d clip_frame=%d ph=%d frontier=%d gap=%d playing=%v\n",
			// 		req, clip_frame, playhead.frame, preview_frontier, playhead.frame-preview_frontier, playhead.playing)
			// }
			if decode_clip_frame_sync(&slot.dec, slot.path, clip_frame, slot.buffer[:]) {
				slot.frontier = req
				slot.have_frontier = true
				slot.has_frame = true
				preview_frontier = req
				slot.tex_dirty = true
				changed = true
			}// else if audio_trace {
				//fmt.printf("[vf] miss req=%d ph=%d frontier=%d\n", req, playhead.frame, preview_frontier)
			//}
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

// find_preview_slot returns the slot and Clip* for a given clip identity
// (asset_id + timeline_start_frame), or (nil, nil, false).
find_preview_slot :: proc(asset_id: u64, timeline_start_frame: i64) -> (^Preview_Slot, ^Clip, bool) {
	for i := 0; i < len(timeline.tracks); i += 1 {
		track := &timeline.tracks[i]
		for j := 0; j < len(track.clips); j += 1 {
			clip := &track.clips[j]
			if clip.asset_id == asset_id && clip.timeline_start_frame == timeline_start_frame {
				for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
					if preview_slots[s].in_use && preview_slots[s].asset_id == asset_id && preview_slots[s].timeline_start_frame == timeline_start_frame {
						return &preview_slots[s], clip, true
					}
				}
			}
		}
	}
	return nil, nil, false
}
