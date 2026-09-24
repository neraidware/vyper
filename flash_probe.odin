package main

import "core:fmt"
import "core:os"
import "core:time"

flash_probe_fail := false

flash_check :: proc(cond: bool, msg: string, args: ..any) {
	if !cond {
		flash_probe_fail = true
		fmt.printf("[flash-probe] FAIL: ")
		fmt.printf(msg, ..args)
		fmt.println()
	}
}

// VYPER_FLASH_PROBE="<video>|<still>": reproduce the "still above a split
// boundary flashes on forward playback" bug from the UI bug report.
//
// Steps, each verified + printed before proceeding (a probe must report the
// arrangement it actually exercised, not the one it assumed):
//   1. import video (lands on storage track 0, k + audio),
//   2. split the clip under the playhead -> two adjacent halves of ONE source,
//   3. import still image; REQUIRE it to be present as an is_still clip,
//   4. walk playhead forward a few frames EACH SIDE of the boundary, calling
//      update_preview_slots() every frame (async_live_mode = true) and on every
//      step record whether the still's clip_id owns any live preview slot.
//
// A still that rides its slot across the boundary never blanks. A still whose
// slot drops and re-acquires (has_frame going false while the video halves hand
// over) is the flash -- that is the drop to catch and count.
flash_probe_run :: proc(v: string) {
	async_import_mode = false
	inp: [4096]u8
	n := 0
	for n < len(v) && n < len(inp) - 1 {
		inp[n] = u8(v[n])
		n += 1
	}
	inp[n] = 0
	vpath := cstring(&inp[0])
	_ = vpath

	// Parse "video|still"
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
	flash_check(bar > 0, "VYPER_FLASH_PROBE expects \"<video>|<still>\" (no '|' found)")
	if bar <= 0 {
		return
	}
	vid_buf: [4096]u8
	for i := 0; i < bar; i += 1 {
		vid_buf[i] = inp[i]
	}
	vid := cstring(&vid_buf[0])
	still_buf: [4096]u8
	for i := 0; i < n - bar - 1; i += 1 {
		still_buf[i] = inp[bar + 1 + i]
	}
	still := cstring(&still_buf[0])

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

	// Import the still and place it ABOVE the halves: bin it, then put it on a
	// fresh track at the visual top (the exact "image above the split" layout).
	// import_media would auto-place it at the end of track 0 -- not the bug.
	still_id := import_media_to_bin(still)
	flash_check(still_id != 0, "still failed to bin (path %q)", string(still))
	insert_track(0)
	sync_track_order()
	still_ti := len(timeline.tracks) - 1
	add_asset_to_timeline(still_id, still_ti, half_a.timeline_start_frame)
	sync_track_order()
	still_clip: ^Clip
	still_track := -1
	for ti := 0; ti < len(timeline.tracks); ti += 1 {
		for ci := 0; ci < len(timeline.tracks[ti].clips); ci += 1 {
			c := &timeline.tracks[ti].clips[ci]
			if c.is_still {
				still_clip = c
				still_track = ti
				break
			}
		}
		if still_track >= 0 {
			break
		}
	}
	if still_clip != nil {
		// The bug layout (what a user ends up with): the image starts flush on
		// the split boundary -- its left edge IS the cut. import bounds a still
		// to a default span; put the still's start exactly at the boundary, then
		// give it enough tail to cover the forward walk below.
		still_clip.timeline_start_frame = half_b.timeline_start_frame
		still_clip.source_length_frames = 30
	}
	fmt.println("[flash-probe] post-still layout")
	for ti := 0; ti < len(timeline.tracks); ti += 1 {
		fmt.printf(
			"[flash-probe]   track %d name=%q clips=%d\n",
			ti,
			timeline.tracks[ti].name,
			len(timeline.tracks[ti].clips),
		)
	}
	flash_check(still_clip != nil, "imported still must exist as an is_still clip")
	if still_clip != nil {
		still_spans :=
			still_clip^.
			timeline_start_frame <= half_b.timeline_start_frame &&
			clip_timeline_end(still_clip^) > half_b.timeline_start_frame
		fmt.printf(
			"[flash-probe] still on track %d spans_boundary_to=%v end=%d\n",
			still_track,
			still_spans,
			clip_timeline_end(still_clip^),
		)
	}

	flash_probe_fail = false // re-arm; only has_frame drops below are failures
	async_live_mode = true // must match real playback: async decode into slots

	still_slot_clip_id := u64(0)
	if still_clip != nil {
		still_slot_clip_id = still_clip.clip_id
	}

	// REPRODUCE the flash: play FORWARD across the boundary with the still
	// starting exactly ON the cut. prewarm_next_clip only runs during forward
	// playback (playhead.playing && playback_dir==1); with the old code the
	// still was invisible to prewarm (nothing covered its track before its
	// start), so its slot cold-claimed at frame==boundary and has_frame went
	// false until the async decode landed -- the flash.  With the fix, prewarm
	// warms the still's single frame ahead of the crossing and the slot primes
	// from warm, so has_frame must be true on the still's very first frame.
	// Play through half A's tail first: prewarm runs on these frames and must
	// target the still starting at the cut. Verify it BEFORE the crossing.
	playhead.playing = true
	playback_dir = 1
	active_interaction = .None
	playhead.frame = still_clip.timeline_start_frame - 3
	update_preview_slots()
	flash_check(
		warm_valid && warm_clip_id == still_slot_clip_id,
		"prewarm must target the soon-starting still (warm_id=%d still_id=%d warm_valid=%v)",
		warm_clip_id,
		still_slot_clip_id,
		warm_valid,
	)
	still_drops := 0
	for f := still_clip.timeline_start_frame; f < still_clip.timeline_start_frame + 5; f += 1 {
		playhead.frame = f
		update_preview_slots()
		still_ok := false
		for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
			slot := &preview_slots[s]
			if slot.in_use && slot.has_frame && slot.clip_id == still_slot_clip_id {
				still_ok = true
			}
		}
		if !still_ok {
			still_drops += 1
			fmt.printf(
				"[flash-probe] frame=%d STILL DARK\n",
				f,
			)
		}
		fmt.printf(
			"[flash-probe] frame=%d still_has_frame=%v after_start=%d drops=%d\n",
			f,
			still_ok,
			f - still_clip.timeline_start_frame,
			still_drops,
		)
		time.sleep(3 * time.Millisecond)
	}
	fmt.printf(
		"[flash-probe] playing forward: still first-frame drops=%d\n",
		still_drops,
	)
	if still_drops > 0 {
		flash_probe_fail = true
	}

	fmt.println("[flash-probe] file:", v)
	if flash_probe_fail {
		fmt.println("[flash-probe] FAILED (still lost its slot across the boundary)")
		os.exit(1)
	}
	fmt.println("[flash-probe] OK")
	os.exit(0)
}