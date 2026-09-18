package main

import "core:fmt"
import "core:os"

// Timeline probe (VYPER_TL_PROBE): headless regression checks for the clip-edit
// paths — the playhead-coverage split (cut the clip UNDER the playhead), the
// linked-group split fanout, and the never-desync invariants for linked-group
// drag/drop/resize. Builds its own timeline state directly; no decode, no SDL.

tl_probe_fail := false

tl_probe_check :: proc(cond: bool, msg: string, args: ..any) {
	if !cond {
		tl_probe_fail = true
		line := fmt.tprintf(msg, ..args)
		fmt.println("[tl-probe] FAIL", line)
	}
}

mk_tl_clip :: proc(cid, link: u64, start, slen, tstart: i64, kind: Media_Kind) -> Clip {
	return Clip {
		clip_id = cid,
		link_id = link,
		kind = kind,
		source_start_frame = 0,
		source_length_frames = slen,
		timeline_start_frame = tstart,
	}
}

// tl_scene builds the standard probe timeline:
//
//	track 0: V  (video) start 10 len 100 src 200  link L1
//	track 1: A  (audio) start 10 len 90  src 200  link L1
//	track 2: V2 (video) start 0  len 40  src 200  no link
tl_scene :: proc() {
	timeline = Timeline {
		tracks = make([dynamic]Track, 0, 4, context.temp_allocator),
	}
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 8, context.temp_allocator)})
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 8, context.temp_allocator)})
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 8, context.temp_allocator)})
	append(&timeline.tracks[0].clips, mk_tl_clip(1001, 9001, 10, 100, 10, .Video))
	append(&timeline.tracks[1].clips, mk_tl_clip(1002, 9001, 10, 90, 10, .Audio))
	append(&timeline.tracks[2].clips, mk_tl_clip(1003, 0, 0, 40, 0, .Video))
	selected_track = -1
	selected_index = -1
	playhead.frame = 0
	timeline_view_start = 0
	drag_group_delta = 0
	clear(&drag_group_orig)
}

// tl_single_clip_scene replaces the timeline with one unlinked clip on one
// track, for the ripple playhead-follow checks (which only care about the
// playhead frame and one clip's placement).
tl_single_clip_scene :: proc(clip_start, clip_len: i64) {
	timeline = Timeline {
		tracks = make([dynamic]Track, 0, 1, context.temp_allocator),
	}
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 4, context.temp_allocator)})
	append(
		&timeline.tracks[0].clips,
		mk_tl_clip(3001, 0, 0, clip_len, clip_start, .Video),
	)
	selected_track = -1
	selected_index = -1
	timeline_view_start = 0
}

// tl_group_starts returns the current timeline starts of the two L1 members
// (video clip 1001, then audio clip 1002) for the standard scene. Resolves by
// clip id — vertical drops relocate members to other tracks.
tl_group_starts :: proc() -> (vstart, astart: i64) {
	for &tr in timeline.tracks {
		for &c in tr.clips {
			switch c.clip_id {
			case 1001:
				vstart = c.timeline_start_frame
			case 1002:
				astart = c.timeline_start_frame
			}
		}
	}
	return
}

// tl_two_starts returns the starts of the first two clips on track 0 (the
// same-lane two-video scene in test_drag_same_track_leftedge).
tl_two_starts :: proc() -> (s1, s2: i64) {
	s1 = timeline.tracks[0].clips[0].timeline_start_frame
	s2 = timeline.tracks[0].clips[1].timeline_start_frame
	return
}

// tl_link_of returns the link_id of the clip with the given id, wherever it
// lives now.
tl_link_of :: proc(cid: u64) -> u64 {
	for &tr in timeline.tracks {
		for &c in tr.clips {
			if c.clip_id == cid {
				return c.link_id
			}
		}
	}
	return 0
}

// tl_assert_aligned fails unless every clip grouping by nonzero link_id has all
// its members on the same timeline start.
tl_assert_aligned :: proc(what: string) {
	heads := make(map[u64]i64, 8, context.temp_allocator)
	defer delete(heads)
	bad := ""
	for &tr in timeline.tracks {
		for &c in tr.clips {
			if c.link_id == 0 {
				continue
			}
			if known, ok := heads[c.link_id]; ok {
				if c.timeline_start_frame != known {
					bad = fmt.tprintf(
						"link=%d clip_id=%d start=%d vs %d",
						c.link_id,
						c.clip_id,
						c.timeline_start_frame,
						known,
					)
				}
			} else {
				heads[c.link_id] = c.timeline_start_frame
			}
		}
	}
	tl_probe_check(len(bad) == 0, "%s desync: %s", what, bad)
}

// test_cut_resolves_playhead: with the selection somewhere ELSE (V2 doesn't
// straddle), S must cut the clip under the playhead, fanning out to the whole
// link group. ("not cutting the right shit" — the old code refused because the
// selected clip didn't straddle the playhead.)
test_cut_resolves_playhead :: proc() {
	selected_track = 2
	selected_index = 0
	playhead.frame = 60
	split_clip_at_playhead()

	tl_probe_check(
		len(timeline.tracks[0].clips) == 2,
		"playhead split: track0 must have 2 clips, has %d",
		len(timeline.tracks[0].clips),
	)
	tl_probe_check(
		len(timeline.tracks[1].clips) == 2,
		"playhead split: track1 must have 2 clips, has %d",
		len(timeline.tracks[1].clips),
	)
	tl_probe_check(
		len(timeline.tracks[2].clips) == 1,
		"playhead split: track2 (selection) must stay 1 clip, has %d",
		len(timeline.tracks[2].clips),
	)

	v0 := timeline.tracks[0].clips[0]
	v1 := timeline.tracks[0].clips[1]
	a0 := timeline.tracks[1].clips[0]
	a1 := timeline.tracks[1].clips[1]
	tl_probe_check(
		v0.timeline_start_frame == 10 && v0.source_length_frames == 50,
		"V left = [10,60), got start=%d len=%d",
		v0.timeline_start_frame,
		v0.source_length_frames,
	)
	tl_probe_check(
		v1.timeline_start_frame == 60 && v1.source_length_frames == 50,
		"V right = [60,110), got start=%d len=%d",
		v1.timeline_start_frame,
		v1.source_length_frames,
	)
	tl_probe_check(
		a0.timeline_start_frame == 10 && a0.source_length_frames == 50,
		"A left = [10,60), got start=%d len=%d",
		a0.timeline_start_frame,
		a0.source_length_frames,
	)
	tl_probe_check(
		a1.timeline_start_frame == 60 && a1.source_length_frames == 40,
		"A right = [60,100), got start=%d len=%d",
		a1.timeline_start_frame,
		a1.source_length_frames,
	)

	tl_probe_check(
		v0.link_id == 9001 && a0.link_id == 9001,
		"left halves must keep the original link 9001 (got %d,%d)",
		v0.link_id,
		a0.link_id,
	)
	tl_probe_check(
		v1.link_id != 0 && v1.link_id != 9001,
		"right halves must mint a fresh link, got %d",
		v1.link_id,
	)
	tl_probe_check(
		v1.link_id == a1.link_id,
		"both right halves must SHARE one fresh link (got %d,%d)",
		v1.link_id,
		a1.link_id,
	)
	tl_probe_check(
		v0.clip_id == 1001 && a0.clip_id == 1002,
		"left halves keep original clip ids (got %d,%d)",
		v0.clip_id,
		a0.clip_id,
	)
	tl_probe_check(
		v1.clip_id != v0.clip_id && v1.clip_id != a1.clip_id && v1.clip_id != 1003,
		"right halves get fresh clip ids (got %d,%d)",
		v1.clip_id,
		a1.clip_id,
	)
	// Selection should now point at the just-cut clip (its left half).
	tl_probe_check(
		selected_track == 0 && selected_index == 0,
		"selection should move to the cut clip, got (%d,%d)",
		selected_track,
		selected_index,
	)
}

// test_cut_selection_straddle: when the SELECTED clip straddles the playhead,
// S keeps cutting the selection (and its linked partner) exactly as before.
test_cut_selection_straddle :: proc() {
	selected_track = 0
	selected_index = 0
	playhead.frame = 55
	split_clip_at_playhead()

	tl_probe_check(
		len(timeline.tracks[0].clips) == 2 && len(timeline.tracks[1].clips) == 2,
		"selection split: V and A must both split",
	)
	v0 := timeline.tracks[0].clips[0]
	v1 := timeline.tracks[0].clips[1]
	a1 := timeline.tracks[1].clips[1]
	tl_probe_check(
		v0.timeline_start_frame == 10 && v0.source_length_frames == 45,
		"V left [10,55) got %d len %d",
		v0.timeline_start_frame,
		v0.source_length_frames,
	)
	tl_probe_check(
		v1.timeline_start_frame == 55 && v1.source_length_frames == 55,
		"V right [55,110) got %d len %d",
		v1.timeline_start_frame,
		v1.source_length_frames,
	)
	tl_probe_check(
		a1.timeline_start_frame == 55,
		"A right starts at 55, got %d",
		a1.timeline_start_frame,
	)
	tl_probe_check(
		v1.link_id != 9001 && v1.link_id == a1.link_id,
		"right halves share a fresh link",
	)
	tl_assert_aligned("selection split")
}

// test_drag_group_alignment: driving the exact live-drag math — anchor moves to
// orig.start+delta, members via apply_group_drag_to_members — every feasible
// step must leave the group perfectly aligned.
test_drag_group_alignment :: proc() {
	tl_scene()
	capture_link_group(&timeline.tracks[0].clips[0], 0)
	deltas: []i64 = {30, 80, 85, 5, -10}
	for delta in deltas {
		if group_delta_feasible(delta) {
			drag_clip = &timeline.tracks[0].clips[0]
			if drag_clip.timeline_start_frame != drag_group_orig[0].start + delta {
				drag_clip.timeline_start_frame = drag_group_orig[0].start + delta
			}
			apply_group_drag_to_members(delta)
		}
		v, a := tl_group_starts()
		tl_probe_check(v == a, "drag delta=%d desynced: V@%d A@%d", delta, v, a)
	}
	v, a := tl_group_starts()
	tl_probe_check(v == 0 && a == 0, "final delta -10: both at %d/%d (expected 0)", v, a)
	// Past the left edge the group must refuse as a whole (delta -20 would land
	// the anchor at -10): nobody moves, so the pair stays time-aligned.
	tl_probe_check(!group_delta_feasible(-20), "delta -20 must be infeasible (left edge)")
	v, a = tl_group_starts()
	tl_probe_check(v == 0 && a == 0, "left edge holds (V@%d A@%d)", v, a)
}

// test_drag_same_track_leftedge: THIS is the "some linked clips desync" repro.
// Two linked video clips offset on the SAME lane; the per-member gap clamp used
// to let the trailing member ride the full delta while the anchor bottomed out
// at frame 0 — collapsing their 200-frame offset. Group moves must be
// all-or-nothing: either every member lands exactly at m.start+delta or nobody
// moves at all.
test_drag_same_track_leftedge :: proc() {
	tl_scene()
	clear(&timeline.tracks[0].clips)
	append(&timeline.tracks[0].clips, mk_tl_clip(3001, 9002, 0, 100, 0, .Video))
	append(&timeline.tracks[0].clips, mk_tl_clip(3002, 9002, 200, 100, 200, .Video))
	capture_link_group(&timeline.tracks[0].clips[0], 0)
	tl_probe_check(!group_delta_feasible(-50), "-50 must be infeasible (anchor off-timeline)")
	v1, v2 := tl_two_starts()
	tl_probe_check(v1 == 0 && v2 == 200, "left edge holds both (V1@%d V2@%d)", v1, v2)
	tl_probe_check(group_delta_feasible(10), "delta +10 must be feasible")
	drag_clip = &timeline.tracks[0].clips[0]
	drag_clip.timeline_start_frame = 10
	apply_group_drag_to_members(10)
	v1, v2 = tl_two_starts()
	tl_probe_check(v1 == 10 && v2 == 210, "offset preserved (V1@%d V2@%d expected 10/210)", v1, v2)
}

// test_drag_blocked_holds: an infeasible group delta must move NOBODY (anchor
// included) — members must never ride ahead of the anchor.
test_drag_blocked_holds :: proc() {
	append(&timeline.tracks[1].clips, mk_tl_clip(2001, 0, 200, 10, 200, .Audio))
	capture_link_group(&timeline.tracks[0].clips[0], 0)
	// +190 puts the audio member at [200,290) which overlaps blocker [200,210).
	tl_probe_check(!group_delta_feasible(190), "delta +190 must be infeasible (blocked)")
	v, a := tl_group_starts()
	tl_probe_check(v == 10 && a == 10, "blocked delta must move nobody (V@%d A@%d)", v, a)
	// Retreat to a feasible delta must keep everyone aligned.
	tl_probe_check(group_delta_feasible(0), "delta 0 must be feasible")
	drag_clip = &timeline.tracks[0].clips[0]
	drag_clip.timeline_start_frame = drag_group_orig[0].start + 0
	apply_group_drag_to_members(0)
	v, a = tl_group_starts()
	tl_probe_check(v == 10 && a == 10, "retreat keeps V@%d A@%d", v, a)
}

// test_drag_left_blocked_holds: moving a linked group LEFT, one member blocked
// on its own lane while others are free — the whole group must refuse. This is
// the mirrored twin of test_drag_blocked_holds: a non-member sitting ahead (to
// the left) of member B's target slot must freeze the anchor A too, because
// all-or-nothing means nobody advances unless EVERY captured member clears its
// slot.
test_drag_left_blocked_holds :: proc() {
	tl_scene()
	// Rebuild: A (video) and B (audio) linked at 100, drawn hoping to move
	// LEFT; B's lane carries a non-member X occupying [25,65) ahead of B, so a
	// -50 shift parks B at [50,100) right on top of X. The free leftward shift
	// -30 parks both at 70, clear of X (70 > 65).
	clear(&timeline.tracks[0].clips)
	append(&timeline.tracks[0].clips, mk_tl_clip(1001, 9001, 100, 50, 100, .Video))
	clear(&timeline.tracks[1].clips)
	append(&timeline.tracks[1].clips, mk_tl_clip(1002, 9001, 100, 50, 100, .Audio))
	append(&timeline.tracks[1].clips, mk_tl_clip(1102, 0, 25, 40, 25, .Audio))
	capture_link_group(&timeline.tracks[0].clips[0], 0)
	// delta -50 puts B at [50,100), overlapping X's [25,65): must be refused.
	tl_probe_check(!group_delta_feasible(-50), "leftward -50 must be infeasible (B blocked)")
	v, a := tl_group_starts()
	tl_probe_check(v == 100 && a == 100, "blocked leftward must move nobody (V@%d A@%d)", v, a)
	// A free leftward delta that clears B of X must move the whole pair.
	tl_probe_check(group_delta_feasible(-30), "leftward -30 must be feasible (B clears X)")
	drag_clip = &timeline.tracks[0].clips[0]
	drag_clip.timeline_start_frame = drag_group_orig[0].start + -30
	apply_group_drag_to_members(-30)
	v, a = tl_group_starts()
	tl_probe_check(v == 70 && a == 70, "leftward move keeps the pair aligned (V@%d A@%d)", v, a)
}

// test_vertical_drop_alignment: a vertical group drop commits every member at
// m.start + drag_group_delta on its destination lane, all still linked+aligned.
test_vertical_drop_alignment :: proc() {
	capture_link_group(&timeline.tracks[0].clips[0], 0)
	drag_group_delta = 40
	ok := move_linked_group(1)
	tl_probe_check(ok, "vertical drop must succeed")
	v, a := tl_group_starts()
	tl_probe_check(v == 50 && a == 50, "vertical drop: V@%d A@%d (expected 50)", v, a)
	tl_probe_check(
		tl_link_of(1001) == 9001 && tl_link_of(1002) == 9001,
		"links must survive the drop",
	)
}

// test_resize_alignment: head-shift (resize left) moves every member's HEAD by
// the anchor's delta; tail-shift (resize right) moves every tail by the anchor's
// delta. Members must stay time-aligned with the anchor throughout.
test_resize_alignment :: proc() {
	capture_link_group(&timeline.tracks[0].clips[0], 0)
	resize_group_left(&timeline.tracks[0], 0, 25)
	v0 := timeline.tracks[0].clips[0]
	a0 := timeline.tracks[1].clips[0]
	tl_probe_check(
		v0.timeline_start_frame == 25,
		"resize left: anchor head to 25, got %d",
		v0.timeline_start_frame,
	)
	tl_probe_check(
		a0.timeline_start_frame == 25,
		"resize left: audio head to 25, got %d",
		a0.timeline_start_frame,
	)

	capture_link_group(&timeline.tracks[0].clips[0], 0)
	resize_group_right(&timeline.tracks[0], 0, 150)
	v0 = timeline.tracks[0].clips[0]
	a0 = timeline.tracks[1].clips[0]
	tl_probe_check(
		v0.source_length_frames == 125,
		"resize right: V length 125, got %d",
		v0.source_length_frames,
	)
	tl_probe_check(
		a0.timeline_start_frame + a0.source_length_frames == 25 + (90 + 25),
		"resize right: A tail must have moved by the same delta (tail=%d expected %d)",
		a0.timeline_start_frame + a0.source_length_frames,
		25 + 90 + 25,
	)
	tl_assert_aligned("resize")
}

// tl_order_equals asserts the visual stack equals the given storage sequence.
tl_order_equals :: proc(storage: []int) {
	sync_track_order()
	for i in 0 ..< min(len(storage), len(timeline.track_order)) {
		tl_probe_check(
			timeline.track_order[i] == storage[i],
			"track_order[%d] == %d, expected %d (got %v)",
			i,
			timeline.track_order[i],
			storage[i],
			timeline.track_order[:],
		)
	}
	tl_probe_check(
		len(timeline.track_order) == len(storage),
		"track_order len %d, expected %d",
		len(timeline.track_order),
		len(storage),
	)
}

// test_track_reorder checks move_track_to_row's gap-target semantics on the
// standard 3-track scene (storage 0,1,2 in visual order 0,1,2). The track
// arrays themselves must never move (storage indices are stable); only
// track_order changes.
test_track_reorder :: proc() {
	// Storage arrays stay put under any reorder.
	sync_track_order()
	pre_storage := make([dynamic]^Track, 0, 3, context.temp_allocator)
	for i in 0 ..< 3 {
		append(&pre_storage, &timeline.tracks[i])
	}

	// Move track 1 (middle) to the top.
	move_track_to_row(1, 0)
	tl_order_equals([]int{1, 0, 2})

	// Move the now-bottom track 2 to the middle (target gap src_row+1 from
	// its current row 2? no — from row 2, gap 1 is above row 1) → lands at row 1.
	move_track_to_row(2, 1)
	tl_order_equals([]int{1, 2, 0})

	// Same-row gap (src_row == target_row): no-op.
	move_track_to_row(1, 0)
	tl_order_equals([]int{1, 2, 0})

	// Gap immediately below the source (src_row+1): no-op (track already
	// borders that gap).
	move_track_to_row(1, 1)
	tl_order_equals([]int{1, 2, 0})

	// Move the top track to the bottom (gap len).
	move_track_to_row(1, 3)
	tl_order_equals([]int{2, 0, 1})

	// Invalid targets are no-ops.
	move_track_to_row(9, 0)
	tl_order_equals([]int{2, 0, 1})
	move_track_to_row(1, -3)
	tl_order_equals([]int{2, 0, 1})

	// The track ARRAYS never move: the pointers grabbed before still alias the
	// same storage indices.
	tl_probe_check(
		&timeline.tracks[0] == pre_storage[0] &&
			&timeline.tracks[1] == pre_storage[1] &&
			&timeline.tracks[2] == pre_storage[2],
		"reorder must not move the storage arrays",
	)
	tl_probe_check(
		timeline.tracks[1].clips[0].clip_id == 1002,
		"track 1 still holds its clip after reorder",
	)
}

// test_ripple_right_edge_head_trim: a clip whose head starts INSIDE the
// deleted region and extends past its right edge must advance its source by
// the trimmed head length (region_end - clip_start), not by (clip_start -
// region_start). Those coincide only when the clip head sits at the region
// midpoint; everywhere else the wrong value desyncs A/V after a ripple cut.
test_ripple_right_edge_head_trim :: proc() {
	timeline = Timeline {
		tracks = make([dynamic]Track, 0, 2, context.temp_allocator),
	}
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 4, context.temp_allocator)})
	// Head [120,150) sits inside the region [100,150); tail [150,220) survives.
	clip := mk_tl_clip(2001, 0, 0, 100, 120, .Video)
	clip.source_start_frame = 1000
	append(&timeline.tracks[0].clips, clip)

	ripple_delete_region(100, 50)

	tl_probe_check(
		len(timeline.tracks[0].clips) == 1,
		"head-trim: want 1 surviving clip, got %d",
		len(timeline.tracks[0].clips),
	)
	if len(timeline.tracks[0].clips) == 1 {
		k := timeline.tracks[0].clips[0]
		tl_probe_check(
			k.timeline_start_frame == 100 && k.source_start_frame == 1030 && k.source_length_frames == 70,
			"head-trim: want tl=100 src=1030 len=70, got tl=%d src=%d len=%d",
			k.timeline_start_frame,
			k.source_start_frame,
			k.source_length_frames,
		)
	}
}

// test_ripple_playhead_follow: the playhead follows a ripple delete the same
// way the content does -- it shifts left with the closed gap when it was at or
// after the region, clamps to the cut when it was inside the region, and stays
// put when it was before it. A linked-group ripple follows the SELECTED
// member's span (the clip the user deleted), not another member's lane.
test_ripple_playhead_follow :: proc() {
	// After the region: shift left by the removed span.
	tl_single_clip_scene(200, 50)
	playhead.frame = 300
	ripple_delete_region(100, 50)
	tl_probe_check(playhead.frame == 250, "after-region: want 250, got %d", playhead.frame)

	// Inside the region: clamp to the cut.
	tl_single_clip_scene(200, 50)
	playhead.frame = 120
	ripple_delete_region(100, 50)
	tl_probe_check(playhead.frame == 100, "inside-region: want 100, got %d", playhead.frame)

	// Before the region: untouched.
	tl_single_clip_scene(200, 50)
	playhead.frame = 50
	ripple_delete_region(100, 50)
	tl_probe_check(playhead.frame == 50, "before-region: want 50, got %d", playhead.frame)

	// Exactly at the cut: unchanged (the cut is where it already is).
	tl_single_clip_scene(200, 50)
	playhead.frame = 100
	ripple_delete_region(100, 50)
	tl_probe_check(playhead.frame == 100, "at-cut: want 100, got %d", playhead.frame)

	// The view pans by the playhead's delta, so the playhead keeps its on-screen
	// position while the gap collapses.
	tl_single_clip_scene(200, 50)
	timeline_view_start = 200
	playhead.frame = 300
	ripple_delete_region(100, 50)
	tl_probe_check(
		playhead.frame == 250 && timeline_view_start == 150,
		"view-pan after-region: want ph 250 view 150, got ph %d view %.0f",
		playhead.frame,
		timeline_view_start,
	)

	// Before the region: the playhead doesn't move, so the view doesn't pan.
	tl_single_clip_scene(200, 50)
	timeline_view_start = 200
	playhead.frame = 50
	ripple_delete_region(100, 50)
	tl_probe_check(
		playhead.frame == 50 && timeline_view_start == 200,
		"view-pan before-region: want ph 50 view 200, got ph %d view %.0f",
		playhead.frame,
		timeline_view_start,
	)

	// Linked group: playhead follows the selected member's span.
	timeline = Timeline {
		tracks = make([dynamic]Track, 0, 2, context.temp_allocator),
	}
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 4, context.temp_allocator)})
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 4, context.temp_allocator)})
	append(&timeline.tracks[0].clips, mk_tl_clip(3101, 777, 0, 50, 200, .Video))
	append(&timeline.tracks[1].clips, mk_tl_clip(3102, 777, 0, 50, 200, .Audio))
	selected_track = 0
	selected_index = 0
	playhead.frame = 250
	ripple_delete_linked_group(777)
	tl_probe_check(playhead.frame == 200, "linked-group: want 200, got %d", playhead.frame)
}

// test_still_resize_free: a still image's synthetic one-second length (its
// synthetic frame_count) is a default length, NOT a media bound, so both edges
// resize freely and source_start_frame stays 0 across resize and split (the
// image shows the same frame everywhere).
test_still_resize_free :: proc() {
	timeline = Timeline {
		tracks = make([dynamic]Track, 0, 1, context.temp_allocator),
	}
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 4, context.temp_allocator)})
	c := mk_tl_clip(4001, 0, 0, 60, 100, .Video)
	c.is_still = true
	append(&timeline.tracks[0].clips, c)
	selected_track = 0
	selected_index = 0

	// Right edge: grow far past the 60-frame (1 s) default.
	got := resize_clip_right(&timeline.tracks[0], 0, 100 + 600)
	tl_probe_check(got == 600, "still resize right: want 600, got %d", got)

	// Left edge: grow left to frame 0; a still never advances its source.
	got = resize_clip_left(&timeline.tracks[0], 0, 0)
	tl_probe_check(
		got == 700 && timeline.tracks[0].clips[0].source_start_frame == 0,
		"still resize left: want len 700 src 0, got len %d src %d",
		got,
		timeline.tracks[0].clips[0].source_start_frame,
	)

	// Split at the middle: the right half must keep source offset 0.
	playhead.frame = 350
	split_clip_at_playhead()
	tl_probe_check(
		len(timeline.tracks[0].clips) == 2 &&
		timeline.tracks[0].clips[1].source_start_frame == 0 &&
		timeline.tracks[0].clips[1].is_still,
		"still split: want 2 stills, right src 0; got %d clips, right src %d",
		len(timeline.tracks[0].clips),
		len(timeline.tracks[0].clips) == 2 ? timeline.tracks[0].clips[1].source_start_frame : -1,
	)
}

timeline_probe_run :: proc(_: string) {
	tl_scene()
	test_cut_resolves_playhead()
	fmt.println("[tl-probe] cut-resolves ok")
	tl_scene()
	test_cut_selection_straddle()
	fmt.println("[tl-probe] cut-straddle ok")
	tl_scene()
	test_drag_group_alignment()
	fmt.println("[tl-probe] drag-alignment ok")
	tl_scene()
	test_drag_same_track_leftedge()
	fmt.println("[tl-probe] same-track ok")
	tl_scene()
	test_drag_blocked_holds()
	fmt.println("[tl-probe] blocked-holds ok")
	tl_scene()
	test_drag_left_blocked_holds()
	fmt.println("[tl-probe] left-blocked ok")
	tl_scene()
	test_vertical_drop_alignment()
	fmt.println("[tl-probe] vertical-drop ok")
	tl_scene()
	test_resize_alignment()
	fmt.println("[tl-probe] resize ok")

	test_still_resize_free()
	fmt.println("[tl-probe] still-resize ok")

	tl_scene()
	test_ripple_right_edge_head_trim()
	fmt.println("[tl-probe] ripple-head-trim ok")

	tl_scene()
	test_ripple_playhead_follow()
	fmt.println("[tl-probe] ripple-playhead-follow ok")

	// Reorder-by-gap semantics of move_track_to_row: target_row is the visual
	// stack position (0 = top, len = bottom); the same-row gap (src_row) and the
	// gap immediately below (src_row+1) are no-ops, everything else lands the
	// track at that visual position.
	tl_scene()
	test_track_reorder()
	fmt.println("[tl-probe] track-reorder ok")

	if tl_probe_fail {
		fmt.println("[tl-probe] FAILED")
		os.exit(1)
	}
	fmt.println("[tl-probe] all checks passed")
	os.exit(0)
}
