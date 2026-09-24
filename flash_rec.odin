package main

import "core:fmt"
import "core:os"

// VYPER_FLASH_REC=1: register, don't construct. In the real frame loop
// (frame.odin render_ui_frame) after update_preview_slots(), this watches the
// CURRENT timeline arrangement while the user just plays through their split
// boundary and logs every time a still clip's preview slot drops or re-gains
// has_frame, with the frame + whether the playhead is on a same-source boundary
// directly under the still at that instant.
//
// It never mutates the timeline or the slots -- it reads the live arrangement
// the user built by hand and reports what the preview actually did.
flash_rec_enabled := false

// last-state per watched clip_id: false->true = restore, true->false = drop.
flash_rec_last: map[u64]bool

flash_rec_init :: proc() {
	if v, _ := os.lookup_env_alloc("VYPER_FLASH_REC", context.temp_allocator); v != "" {
		flash_rec_enabled = true
	}
}

// Is clip (on storage track ti) a still that covers a same-source adjacent
// video half pair on a different track? That's the "image above a split
// boundary" arrangement the bug lives in.
flash_rec_should_watch :: proc(ti: int, ci: ^Clip) -> bool {
	if ci == nil || !ci.is_still {
		return false
	}
	start := ci.timeline_start_frame
	end := ci.timeline_start_frame + ci.source_length_frames
	if end - start < 2 {
		return false
	}
	for ti2 in 0 ..< len(timeline.tracks) {
		if ti2 == ti {
			continue
		}
		t := &timeline.tracks[ti2]
		for cj in 0 ..< len(t.clips) {
			c := &t.clips[cj]
			if c.kind != .Video || c.is_still {
				continue
			}
			c_start := c.timeline_start_frame
			c_end := c.timeline_start_frame + c.source_length_frames
			if c_end <= start || c_start >= end {
				continue
			}
			// Same-source half pair meeting end-to-end, boundary under still.
			if cj + 1 < len(t.clips) {
				next := &t.clips[cj + 1]
				if next.kind == .Video && next.path == c.path &&
				   next.timeline_start_frame == c_end {
					return true
				}
			}
			if cj > 0 {
				prev := &t.clips[cj - 1]
				if prev.kind == .Video && prev.path == c.path &&
				   prev.timeline_start_frame + prev.source_length_frames == c_start {
					return true
				}
			}
		}
	}
	return false
}

flash_rec_after_slots :: proc() {
	if !flash_rec_enabled {
		return
	}
	// update_preview_slots just ran for this frame. For each watched still,
	// does it hold a live slot with a frame right now? Log only transitions:
	// a flash shows up as has_frame going true->false (blank) then false->true
	// (re-render).
	for ti in 0 ..< len(timeline.tracks) {
		t := &timeline.tracks[ti]
		for ci := 0; ci < len(t.clips); ci += 1 {
			c := &t.clips[ci]
			if !flash_rec_should_watch(ti, c) {
				continue
			}
			live := false
			for s in 0 ..< MAX_PREVIEW_SLOTS {
				slot := &preview_slots[s]
				if slot.in_use && slot.clip_id == c.clip_id && slot.has_frame {
					live = true
					break
				}
			}
			prev, seen := flash_rec_last[c.clip_id]
			if !seen || prev != live {
				fmt.printf(
					"[flash-rec] frame=%d still clip=%d has_frame -> %v (on-boundary=%v)\n",
					playhead.frame,
					c.clip_id,
					live,
					flash_rec_on_boundary(c),
				)
			}
			flash_rec_last[c.clip_id] = live
		}
	}
}

// Called from the three slot-freeing sites in update_preview_slots. Logs a
// tagged line naming WHY a slot died, but only when the dying slot held a
// still clip (is_still) and the recorder is enabled -- normal steady-state
// churn of video halves stays silent.
flash_rec_note_kill :: proc(slot_idx: int, reason: cstring) {
	if !flash_rec_enabled {
		return
	}
	if slot_idx < 0 {
		return
	}
	slot := &preview_slots[slot_idx]
	if !slot.in_use || slot.path == nil || !slot_held_still(slot) {
		return
	}
	// Classify the sweep: was the still legitimately out of playhead range, or
	// did it still cover the playhead and get skipped by the walk anyway?
	// Only meaningful for sweep -- anchor-shift/reassign claims the slot (the
	// still IS the claiming clip), so "covered" there is normal, not a skip.
	covered := false
	see_clip := slot_clip_with_id(slot.clip_id)
	if see_clip != nil {
		covered =
			playhead.frame >= see_clip.timeline_start_frame &&
			playhead.frame < see_clip.timeline_start_frame + see_clip.source_length_frames
	}
	span_desc: [64]u8
	if see_clip != nil {
		fmt.bprintf(
			span_desc[:],
			" span=[%d,%d)",
			see_clip.timeline_start_frame,
			see_clip.timeline_start_frame + see_clip.source_length_frames,
		)
	} else {
		fmt.bprintf(span_desc[:], " span=?")
	}
	fmt.printf(
		"[flash-rec] frame=%d slot=%d clip=%d still KILLED by %s (has_frame_was=%v covered=%v warm_valid=%v warm_clip=%d playing=%v dir=%d)%s\n",
		playhead.frame,
		slot_idx,
		slot.clip_id,
		reason,
		slot.has_frame,
		covered,
		warm_valid,
		warm_clip_id,
		playhead.playing,
		playback_dir,
		span_desc[:],
	)
	if reason == "sweep" && covered {
		fmt.printf(
			"[flash-rec]   ^ still covered playhead yet swept -- walk skip is the bug candidate\n",
		)
	}
}

// Resolve a slot's still clip back from its stored clip_id (the slot does not
// carry the clip span or is_still, just clip_id/path/asset).
slot_clip_with_id :: proc(clip_id: u64) -> ^Clip {
	for ti in 0 ..< len(timeline.tracks) {
		t := &timeline.tracks[ti]
		for ci := 0; ci < len(t.clips); ci += 1 {
			c := &t.clips[ci]
			if c.clip_id == clip_id {
				return c
			}
		}
	}
	return nil
}

// Did this slot's clip map to an is_still clip? Sneaky re-check via the live
// timeline (the slot only stores clip_id/path + asset_id, not is_still).
slot_held_still :: proc(slot: ^Preview_Slot) -> bool {
	for ti in 0 ..< len(timeline.tracks) {
		t := &timeline.tracks[ti]
		for ci := 0; ci < len(t.clips); ci += 1 {
			c := &t.clips[ci]
			if c.clip_id == slot.clip_id {
				return c.is_still
			}
		}
	}
	return false
}

// Is the playhead exactly on a same-source video half boundary that passes
// under this still clip?
flash_rec_on_boundary :: proc(ci: ^Clip) -> bool {
	start := ci.timeline_start_frame
	end := ci.timeline_start_frame + ci.source_length_frames
	f := playhead.frame
	for ti in 0 ..< len(timeline.tracks) {
		t := &timeline.tracks[ti]
		if len(t.clips) == 0 {
			continue
		}
		for cj := 0; cj + 1 < len(t.clips); cj += 1 {
			a := &t.clips[cj]
			b := &t.clips[cj + 1]
			if a.kind != .Video || b.kind != .Video || a.is_still || b.is_still {
				continue
			}
			if a.path != b.path ||
			   b.timeline_start_frame != a.timeline_start_frame + a.source_length_frames {
				continue
			}
			if f == b.timeline_start_frame && f >= start && f < end {
				return true
			}
		}
	}
	return false
}