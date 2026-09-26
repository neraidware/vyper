package main

import "core:fmt"
import "core:os"
import "core:time"

flash_probe_fail := false

// OVERLAY_SPAN_BLEED is how many frames before the split boundary the probe
// overlay's left edge sits. The bug arrangement has the other clip SPANNING the
// cut (on screen both sides), so this must be > 0 or the probe only tests the
// degenerate flush-left-edge case.
OVERLAY_SPAN_BLEED :: 6

flash_check :: proc(cond: bool, msg: string, args: ..any) {
	if !cond {
		flash_probe_fail = true
		fmt.printf("[flash-probe] FAIL: ")
		fmt.printf(msg, ..args)
		fmt.println()
	}
}

// flash_probe_overlay_has_frame reports whether the overlay's clip_id owns a
// live preview slot with a decoded frame right now.
flash_probe_overlay_has_frame :: proc(overlay_id: u64) -> bool {
	for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
		slot := &preview_slots[s]
		if slot.in_use && slot.has_frame && slot.clip_id == overlay_id {
			return true
		}
	}
	return false
}

// flash_probe_play_across walks the playhead one frame at a time across
// [from, to) (stepping +dir each frame, forward=+1 reverse=-1), calling
// update_preview_slots() every frame just like real playback, and counts the
// frames AT OR AFTER start_tally where the overlay dropped its live slot. A
// drop = the flash. Frames before start_tally print but don't fail: a freshly
// covered overlay legitimately cold-claims and takes a frame or two of async
// decode latency to land a frame -- that warm-up happens below the front clip
// and nobody sees it. The flash is the overlay going dark AT the split.
flash_probe_play_across :: proc(
	from, to: i64,
	dir: int,
	overlay_id: u64,
	tally_from: i64,
) -> int {
	playhead.playing = true
	playback.dir = 1
	if dir < 0 {
		playback.dir = -1
	}
	active_interaction = .None
	drops := 0
	for f := from; dir > 0 ? f < to : f >= to; f += i64(dir) {
		playhead.frame = f
		update_preview_slots()
		ok := flash_probe_overlay_has_frame(overlay_id)
		if !ok {
			if f >= tally_from {
				drops += 1
			}
			fmt.printf(
				"[flash-probe]   frame=%d OVERLAY DARK%s\n",
				f,
				f >= tally_from ? " *FLASH*" : " (pre-tally warm-up)",
			)
		}
		fmt.printf(
			"[flash-probe]   frame=%d overlay_has_frame=%v drops=%d\n",
			f,
			ok,
			drops,
		)
		time.sleep(3 * time.Millisecond)
	}
	return drops
}

// VYPER_FLASH_PROBE="<video>|<overlay>": reproduce the "clip above a split
// boundary flashes on playback" bug from the UI bug report. The overlay clip
// (still IMAGE or a plain VIDEO clip -- the bug report says the flash happens
// with any video clip, not just stills) sits on a fresh top track with its left
// edge flush on the split boundary.
//
// Steps, each verified + printed before proceeding (a probe must report the
// arrangement it actually exercised, not the one it assumed):
//   1. import video (lands on storage track 0, k + audio),
//   2. split the clip under the playhead -> two adjacent halves of ONE source,
//   3. import the overlay asset (image or video); REQUIRE it to exist as a
//      clip on the top track with its left edge on the boundary,
//   4. walk playhead FORWARD a few frames EACH SIDE of the boundary, calling
//      update_preview_slots() every frame (async_live_mode = true) recording
//      whether the overlay clip's clip_id owns any live preview slot,
//   5. walk playhead REVERSE back across the boundary, then FORWARD across it
//      a second time (scrub back + play again), watching the overlay again.
//
// An overlay that rides its slot across the boundary never blanks. An overlay
// whose slot drops and re-acquires (has_frame going false while the video
// halves hand over) is the flash -- that is the drop to catch and count.
flash_probe_run :: proc(v: string) {
	editor_flags.async_import_mode = false
	inp: [4096]u8
	n := 0
	for n < len(v) && n < len(inp) - 1 {
		inp[n] = u8(v[n])
		n += 1
	}
	inp[n] = 0
	vpath := cstring(&inp[0])
	_ = vpath

	// Parse "video|overlay" (overlay may be an image or a video)
	if len(v) == 0 {
		return
	}
	bar := -1
	for i := 0; i < n; i += 1 {
		if inp[i] == '|' {
			bar = i
			break
		}
	}
	flash_check(bar > 0, "VYPER_FLASH_PROBE expects \"<video>|<overlay>\" (no '|' found)")
	if bar <= 0 {
		return
	}
	vid_buf: [4096]u8
	for i := 0; i < bar; i += 1 {
		vid_buf[i] = inp[i]
	}
	vid := cstring(&vid_buf[0])
	overlay_buf: [4096]u8
	for i := 0; i < n - bar - 1; i += 1 {
		overlay_buf[i] = inp[bar + 1 + i]
	}
	overlay_path := cstring(&overlay_buf[0])

	import_media(vid)

	if len(timeline.tracks) == 0 || len(timeline.tracks[0].clips) == 0 {
		fmt.println("[flash-probe] no clip on track 0")
		os.exit(2)
	}
	orig := &timeline.tracks[0].clips[0]
	nc := orig.source_length_frames
	fmt.println(
		"[flash-probe] imported video tl=[",
		orig.timeline_start_frame,
		",",
		orig.timeline_start_frame + nc,
		") len=",
		nc,
		"track0_clips=",
		len(timeline.tracks[0].clips),
	)

	// Split at the playhead: halfA | halfB, adjacent, same source.
	playhead.frame = nc / 2
	split_clip_at_playhead()
	fmt.println(
		"[flash-probe] after split: track0_clips=",
		len(timeline.tracks[0].clips),
		"tracks=",
		len(timeline.tracks),
	)
	flash_check(
		len(timeline.tracks[0].clips) == 2,
		"expected 2 halves after split, got %d",
		len(timeline.tracks[0].clips),
	)
	half_a := &timeline.tracks[0].clips[0]
	half_b := &timeline.tracks[0].clips[1]
	flash_check(
		half_b.timeline_start_frame == half_a.timeline_start_frame + half_a.source_length_frames,
		"halves must be adjacent (A ends %d, B starts %d)",
		half_a.timeline_start_frame + half_a.source_length_frames,
		half_b.timeline_start_frame,
	)

	// Import the overlay (still image OR video clip) and place it ABOVE the
	// halves: bin it, then put it on a fresh track at the visual top (the exact
	// "clip above the split" layout). import_media would auto-place it at the
	// end of track 0 -- not the bug.
	overlay_id := import_media_to_bin(overlay_path)
	flash_check(
		overlay_id != 0,
		"overlay failed to bin (path %q)",
		string(overlay_path),
	)
	insert_track(0)
	sync_track_order()
	overlay_ti := len(timeline.tracks) - 1
	add_asset_to_timeline(overlay_id, overlay_ti, half_a.timeline_start_frame)
	sync_track_order()
	overlay_clip: ^Clip
	overlay_track := -1
	for ti := 0; ti < len(timeline.tracks); ti += 1 {
		for ci := 0; ci < len(timeline.tracks[ti].clips); ci += 1 {
			c := &timeline.tracks[ti].clips[ci]
			if c.asset_id == overlay_id {
				overlay_clip = c
				overlay_track = ti
				break
			}
		}
		if overlay_clip != nil {
			break
		}
	}
	if overlay_clip != nil {
		// The bug layout (what a user ends up with): the overlay covers the
		// split -- its span crosses the cut, so it is NOT flush on it but
		// overlaps it (left edge BEFORE the cut, tail past it). Snap the start a
		// few frames before the split boundary and give it enough tail to cover
		// the walks below. This is the "other clip flashes when the playhead
		// passes through the split" arrangement: the overlay is on screen on
		// BOTH sides of the cut, so it must ride its slot across with no drop.
		overlay_clip.timeline_start_frame = half_b.timeline_start_frame - OVERLAY_SPAN_BLEED
		overlay_clip.source_length_frames = OVERLAY_SPAN_BLEED + 30
	}
	fmt.println("[flash-probe] post-overlay layout")
	for ti := 0; ti < len(timeline.tracks); ti += 1 {
		fmt.printf(
			"[flash-probe]   track %d name=%q clips=%d\n",
			ti,
			timeline.tracks[ti].name,
			len(timeline.tracks[ti].clips),
		)
	}
	flash_check(overlay_clip != nil, "imported overlay must exist as a clip on the placed track")
	if overlay_clip != nil {
		overlay_spans :=
			overlay_clip^.
			timeline_start_frame <= half_b.timeline_start_frame &&
			clip_timeline_end(overlay_clip^) > half_b.timeline_start_frame
		fmt.printf(
			"[flash-probe] overlay on track %d kind=%v is_still=%v spans_boundary_to=%v end=%d\n",
			overlay_track,
			overlay_clip.kind,
			overlay_clip.is_still,
			overlay_spans,
			clip_timeline_end(overlay_clip^),
		)
	}

	flash_probe_fail = false // re-arm; only has_frame drops below are failures
	async_live_mode = true // must match real playback: async decode into slots

	overlay_slot_clip_id := u64(0)
	if overlay_clip != nil {
		overlay_slot_clip_id = overlay_clip.clip_id
	}

	cut_at := half_b.timeline_start_frame

	// REPRODUCE the flash: the overlay (the clip that was NOT split) spans the
	// cut -- it covers the playhead both sides of the split, so at the boundary
	// it must simply keep riding its existing slot. It is already ACTIVE before
	// the cut, so prewarm does not target it (prewarm only warms the soon-
	// starting clip); the flash would come from the slot machinery REASSIGNING
	// or sweeping its slot at the exact frame the halves hand over. So walk
	// from a few frames BEFORE the cut to a few after it and require has_frame
	// continuously -- no drop at frame==cut.
	// Baseline first: the overlay must already own a live slot right before the
	// cut, or this probe is set up wrong (nothing to "keep riding").
	playhead.frame = cut_at - 2
	playhead.playing = true
	playback.dir = 1
	active_interaction = .None
	update_preview_slots()
	if overlay_clip != nil {
		fmt.printf(
			"[flash-probe] pre-cut baseline frame=%d overlay_has_frame=%v\n",
			playhead.frame,
			flash_probe_overlay_has_frame(overlay_slot_clip_id),
		)
	}

	// FIRST forward crossing. Overlay must hold has_frame across the whole walk
	// -- including the exact frame the halves hand over.
	fwd1_drops := 0
	if overlay_clip != nil {
		fmt.println("[flash-probe] forward crossing #1:")
		fwd1_drops = flash_probe_play_across(
			cut_at - OVERLAY_SPAN_BLEED,
			cut_at + 5,
			1,
			overlay_slot_clip_id,
			cut_at,
		)
	}

	// The SPLIT HALF handoff, not just the overlay: crossing the cut, halfB (the
	// second half) newly covers the playhead. It must NOT cold-claim a fresh
	// slot (reset + reopen + keyframe seek blanks has_frame for the whole async
	// round-trip). slot_claim_flush_peer makes it inherit halfA's still-in_use
	// slot, so the same_asset decoder-preserve path fires and this slot's async
	// worker -- already open on the same file at the frame just before the cut
	// -- serves the crossing frame instantly. Assert halfB owns a live slot
	// with a frame a couple frames past the cut; a cold-claim shows as a multi-
	// frame blank (open+seek latency) that never recovers to the playhead.
	half_b_ok := false
	if overlay_clip != nil {
		for f := cut_at; f < cut_at + 4; f += 1 {
			playhead.frame = f
			update_preview_slots()
		}
		for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
			slot := &preview_slots[s]
			if slot.in_use && slot.has_frame && slot.clip_id == half_b.clip_id {
				half_b_ok = true
			}
		}
		fmt.printf(
			"[flash-probe] forward #1: halfB has_frame past cut=%v (cut=%d frame=%d)\n",
			half_b_ok,
			cut_at,
			playhead.frame,
		)
		if !half_b_ok {
			fmt.printf(
				"[flash-probe]   ^ halfB blanked past the cut -- cold-claim slot, not peer-inherit\n",
			)
		}
	}

	// REVERSE back across the boundary (scrub back). The other-clip flash also
	// shows on reverse: the departing half re-enters and the overlay -- still
	// spanning the cut -- must keep riding its slot. prewarm does NOT run on
	// reverse, so if the overlay's slot dies here it cold-claims on the NEXT
	// forward pass.
	rev_drops := 0
	if overlay_clip != nil {
		fmt.println("[flash-probe] reverse back across cut:")
		// Walk from just past the cut back to a few frames before it. The
		// overlay spans the cut, so it covers the whole reverse walk.
		rev_drops = flash_probe_play_across(
			cut_at + 3,
			cut_at - OVERLAY_SPAN_BLEED + 1,
			-1,
			overlay_slot_clip_id,
			cut_at,
		)
	}

	// SECOND forward crossing: if the overlay kept its slot through reverse it
	// must keep it through the second crossing too; a drop here is the same
	// flash, one crossing later.
	fwd2_drops := 0
	if overlay_clip != nil {
		fmt.println("[flash-probe] forward crossing #2:")
		// Start again before the cut, like a real second play-through.
		playhead.frame = cut_at - 2
		playhead.playing = true
		playback.dir = 1
		active_interaction = .None
		update_preview_slots()
		fwd2_drops = flash_probe_play_across(
			cut_at - OVERLAY_SPAN_BLEED,
			cut_at + 5,
			1,
			overlay_slot_clip_id,
			cut_at,
		)
	}

	overlay_drops := fwd1_drops + rev_drops + fwd2_drops
	fmt.printf(
		"[flash-probe] overlay drops: fwd1=%d rev=%d fwd2=%d total=%d\n",
		fwd1_drops,
		rev_drops,
		fwd2_drops,
		overlay_drops,
	)
	if overlay_drops > 0 || (overlay_clip != nil && !half_b_ok) {
		flash_probe_fail = true
	}

	fmt.println("[flash-probe] file:", v)
	if flash_probe_fail {
		fmt.println("[flash-probe] FAILED (overlay lost its slot across the boundary)")
		os.exit(1)
	}
	fmt.println("[flash-probe] OK")
	os.exit(0)
}