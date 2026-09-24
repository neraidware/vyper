package main

import "core:fmt"
import "core:os"

// VYPER_FLASH_REC=1: register, don't construct. In the real frame loop
// (frame.odin render_ui_frame) after update_preview_slots(), this emits ONE
// comprehensive line per frame while the user scrubs through their split: the
// playhead, whether the frame sits on a same-source half boundary, where the
// warm prewarm decoder points, every clip covering the playhead (span, is_still,
// its compositing layer), and every preview slot's decoded state (has_frame,
// displayed frame, layer). A flash across a boundary shows up as consecutive
// lines where a covering clip's slot has_frame goes true->false->true OR its
// layer drops, with the boundary + warm columns explaining why at a glance.
//
// It never mutates the timeline or the slots -- it reads the live arrangement
// the user built by hand and reports what the preview actually did.
//
// Output goes to a FILE, not just stdout: a GUI app may not have a console, and
// scrubbing + pasting back a log needs it to survive either way. Default sink
// /tmp/vyper_flash_rec.log (truncated each launch); override with
// VYPER_FLASH_LOG=/path. A banner prints to stdout on launch so "is it on?"
// never has to be asked.
flash_rec_enabled := false
flash_rec_file: ^os.File

flash_rec_init :: proc() {
	if v, _ := os.lookup_env_alloc("VYPER_FLASH_REC", context.temp_allocator); v == "" {
		return
	}
	flash_rec_enabled = true
	path := "/tmp/vyper_flash_rec.log"
	if override, _ := os.lookup_env_alloc("VYPER_FLASH_LOG", context.temp_allocator); override != "" {
		path = override
	}
	f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Read_Write_All)
	if err == nil {
		flash_rec_file = f
	}
	fmt.printf("[flash-rec] ENABLED, logging to %s (file_ok=%v)\n", path, flash_rec_file != nil)
}

flash_rec_emit :: proc(line: string) {
	if flash_rec_file != nil {
		fmt.fprintln(flash_rec_file, line)
	}
	fmt.println(line)
}

flash_rec_after_slots :: proc() {
	if !flash_rec_enabled {
		return
	}
	// update_preview_slots just ran for this frame. Emit ONE forensic line per
	// frame so a scrub across the boundary pasted back here tells the whole
	// story: where the playhead is, whether the frame sits on a same-source
	// half boundary with clips above it, what the warm decoder targets, every
	// clip covering the playhead (with its span + name), and every preview
	// slot's has_frame / displayed frame / compositing layer. A flash shows up
	// as a covering clip whose has_frame goes true->false->true in consecutive
	// lines; the boundary + warm + layer columns show why at the same glance.
	ob: [4096]u8
	off := 0
	off += len(fmt.bprintf(
		ob[off:],
		"[flash-rec] f=%d ph=%d play=%v dir=%d scr=%v ",
		playhead.frame,
		playhead.frame,
		playhead.playing,
		playback_dir,
		active_interaction,
	))
	// Same-source half boundary passing under clips above the cut? The
	// recorder's namesake: format + bookmark it before the per-clip detail.
	on_b, b_start, b_end := flash_rec_boundary_at(playhead.frame)
	if on_b {
		off += len(fmt.bprintf(ob[off:], "BOUNDARY(a=[%d,%d)) ", b_start, b_end))
	} else {
		off += len(fmt.bprintf(ob[off:], "boundary=0 "))
	}
	if warm_valid {
		off += len(fmt.bprintf(ob[off:], "warm=%d ", warm_clip_id))
	} else {
		off += len(fmt.bprintf(ob[off:], "warm=none "))
	}
	// Per covering clip: clip_id, span, is_still, layer of its slot (lay=0 =
	// no slot this frame = not composited = the flash when it covers).
	off += len(fmt.bprintf(ob[off:], "clips| "))
	for ti in 0 ..< len(timeline.tracks) {
		t := &timeline.tracks[ti]
		for ci := 0; ci < len(t.clips); ci += 1 {
			c := &t.clips[ci]
			if c.kind != .Video && c.kind != .Text {
				continue
			}
			f := playhead.frame
			if f < c.timeline_start_frame ||
			   f >= c.timeline_start_frame + c.source_length_frames {
				continue
			}
			slot_layer := u8(0)
			for s in 0 ..< MAX_PREVIEW_SLOTS {
				slot := &preview_slots[s]
				if slot.in_use && slot.clip_id == c.clip_id {
					slot_layer = slot.layer
					break
				}
			}
			kind := c.kind == .Text ? "txt" : (c.is_still ? "img" : "vid")
			name: [256]u8
			bname := path_basename(c.path)
			if len(bname) > 255 {
				bname = bname[:255]
			}
			copy(name[:], bname)
			off += len(fmt.bprintf(
				ob[off:],
				"t%d:%s id=%d span=[%d,%d) lay=%d name=%q ",
				ti,
				kind,
				c.clip_id,
				c.timeline_start_frame,
				c.timeline_start_frame + c.source_length_frames,
				slot_layer,
				string(name[:len(bname)]),
			))
		}
	}
	// Per slot: identity, decoded state, compositing rank. A slot whose clip no
	// longer covers (swept this frame) shows clip=0 after the sweep.
	off += len(fmt.bprintf(ob[off:], "slots| "))
	for s in 0 ..< MAX_PREVIEW_SLOTS {
		slot := &preview_slots[s]
		if !slot.in_use {
			off += len(fmt.bprintf(ob[off:], "s%d() ", s))
			continue
		}
		off += len(fmt.bprintf(
			ob[off:],
			"s%d(c=%d hf=%v df=%d lay=%d)%s",
			s,
			slot.clip_id,
			slot.has_frame,
			slot.displayed_frame,
			slot.layer,
			s == MAX_PREVIEW_SLOTS - 1 ? "" : " ",
		))
	}
	flash_rec_emit(string(ob[:off]))
}

// flash_rec_boundary_at returns true when the playhead frame sits exactly on a
// same-source video half boundary (halfA ends at f, halfB starts at f -- either
// ordering works), plus the adjacent halves' span for context. This is the
// arrangement the flash bug lives in: flashing clip covers a playhead frame
// that is simultaneously a cut between two halves of one source on another
// track.
flash_rec_boundary_at :: proc(f: i64) -> (found: bool, a_start, a_end: i64) {
	for ti in 0 ..< len(timeline.tracks) {
		t := &timeline.tracks[ti]
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
			if f == b.timeline_start_frame {
				return true, a.timeline_start_frame, b.timeline_start_frame + b.source_length_frames
			}
		}
	}
	return false, 0, 0
}

// Called from the three slot-freeing sites in update_preview_slots. Logs a
// tagged line naming WHY a slot died plus whether its clip still covered the
// playhead at the killing instant. The reason is the whole point: sweep vs
// anchor-shift vs reassign vs claim tells which free-list decision took the
// slot the flashing clip needed.
flash_rec_note_kill :: proc(slot_idx: int, reason: cstring) {
	if !flash_rec_enabled {
		return
	}
	if slot_idx < 0 {
		return
	}
	slot := &preview_slots[slot_idx]
	if !slot.in_use || slot.path == nil {
		return
	}
	// Covering the playhead when killed = the suspicious case (the walk skipped
	// a clip that should have claimed a slot). Not covering = normal churn.
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
	kb: [512]u8
	kn := len(fmt.bprintf(
		kb[:],
		"[flash-rec] frame=%d slot=%d clip=%d %s KILLED by %s (has_frame_was=%v covered=%v warm_valid=%v warm_clip=%d playing=%v dir=%d)%s\n",
		playhead.frame,
		slot_idx,
		slot.clip_id,
		clip_kind_of(slot.clip_id),
		reason,
		slot.has_frame,
		covered,
		warm_valid,
		warm_clip_id,
		playhead.playing,
		playback_dir,
		span_desc[:],
	))
	flash_rec_emit(string(kb[:kn]))
}

clip_kind_of :: proc(clip_id: u64) -> cstring {
	for ti in 0 ..< len(timeline.tracks) {
		t := &timeline.tracks[ti]
		for ci := 0; ci < len(t.clips); ci += 1 {
			c := &t.clips[ci]
			if c.clip_id == clip_id {
				if c.kind == .Text {
					return "txt"
				}
				return c.is_still ? "img" : "vid"
			}
		}
	}
	return "?"
}

// Resolve a slot's clip back from its stored clip_id (the slot does not
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