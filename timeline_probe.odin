package main

import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"
import "core:strings"

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

// clip_visible_at is half-open on [start, start+length), and the upper bound is
// the one that has to be pinned. main.odin carried `>` where every other site
// used `>=`, so the auto-keyframe gate accepted the playhead one frame past the
// clip end -- and nothing caught it, because this test lived inline in eleven
// places that were free to disagree with each other.
// tl_ripple_dispatch_scene: three abutting UNLINKED clips on one track, the
// middle one selected, playhead parked at 200 (past the cut). Everything the
// Backspace path touches is in play here: the selection, the keyframe-selection
// gate in front of it, and the ripple itself.
tl_ripple_dispatch_scene :: proc() {
	timeline = Timeline {
		tracks = make([dynamic]Track, 0, 1, context.temp_allocator),
	}
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 4, context.temp_allocator)})
	append(&timeline.tracks[0].clips, mk_tl_clip(7101, 0, 0, 100, 0, .Video))
	append(&timeline.tracks[0].clips, mk_tl_clip(7102, 0, 100, 100, 100, .Video))
	append(&timeline.tracks[0].clips, mk_tl_clip(7103, 0, 200, 100, 200, .Video))
	selection.track = 0
	selection.index = 1
	playhead.frame = 250
	timeline_view.start = 0
	active_interaction = .None
	kf_clear()
}

// test_ripple_dispatch_closes_gap drives the ACTUAL Backspace action, not
// ripple_delete_region, because the report was "Backspace ripple delete is not
// working" and the region helper is not where that can break: the action is a
// two-step gate (keyframes first, then selection) around it, and the key
// binding is a third.
test_ripple_dispatch_closes_gap :: proc() {
	tl_probe_check(
		action_for(sdl.K_BACKSPACE, {}) == .Delete_At_Playhead,
		"Backspace must map to Delete_At_Playhead (got %v)",
		action_for(sdl.K_BACKSPACE, {}),
	)
	dispatch_action(.Delete_At_Playhead)

	clips := timeline.tracks[0].clips
	tl_probe_check(
		len(clips) == 2,
		"Backspace on the selected clip must remove exactly one clip (got %d)",
		len(clips),
	)
	if len(clips) != 2 {
		return
	}
	tl_probe_check(
		clips[0].clip_id == 7101 && clips[0].timeline_start_frame == 0,
		"the clip BEFORE the cut must be untouched (got id %d start %d)",
		clips[0].clip_id,
		clips[0].timeline_start_frame,
	)
	// This is the ripple: the tail clip slides left by the removed span. A raw
	// delete would leave it at 200.
	tl_probe_check(
		clips[1].clip_id == 7103 && clips[1].timeline_start_frame == 100,
		"the clip AFTER the cut must slide left to 100 (got id %d start %d)",
		clips[1].clip_id,
		clips[1].timeline_start_frame,
	)
	tl_probe_check(
		playhead.frame == 150,
		"playhead at 250 must follow the ripple to 150 (got %d)",
		playhead.frame,
	)
	tl_probe_check(
		selection.track == -1 && selection.index == -1,
		"the deleted selection must be cleared (got %d/%d)",
		selection.track,
		selection.index,
	)
}

// tl_straddle_scene: one clip spanning the whole ripple region, so the ripple
// has to split it instead of dropping it. Named clips and keyframes, because
// what this test is really about is which half OWNS what afterwards.
tl_straddle_scene :: proc() {
	timeline = Timeline {
		tracks = make([dynamic]Track, 0, 1, context.temp_allocator),
	}
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 2, context.temp_allocator)})
	append(
		&timeline.tracks[0].clips,
		mk_tl_clip(7201, 0, 0, 400, 0, .Video),
	)
	timeline.tracks[0].clips[0].name = session_str_intern("straddle")
	timeline.tracks[0].name = strings.clone("t")
	selection.track = -1
	selection.index = -1
	timeline_view.start = 0
}

// test_ripple_straddle_splits_once: a region strictly inside a clip must leave
// exactly TWO clips — left [0,cut) and right [cut,400) — with different ids.
// The straddle branch appended `left` twice, so the ripple duplicated the left
// half; two clips sharing one clip_id also breaks every clip_id-keyed path.
test_ripple_straddle_splits_once :: proc() {
	tl_straddle_scene()
	ripple_delete_region(100, 50)
	clips := timeline.tracks[0].clips
	tl_probe_check(
		len(clips) == 2,
		"a straddle ripple must leave 2 clips (got %d — the left half was duplicated)",
		len(clips),
	)
	if len(clips) != 2 {
		return
	}
	tl_probe_check(
		clips[0].timeline_start_frame == 0 &&
		clips[0].source_length_frames == 100 &&
		clips[1].timeline_start_frame == 100 &&
		// 400 frames of clip minus the 50 removed leaves 350; the right piece
		// starts at 100, so it is 250 long.
		clips[1].source_length_frames == 250,
		"straddle halves wrong: [%d+%d] [%d+%d], want [0+100] [100+250]",
		clips[0].timeline_start_frame,
		clips[0].source_length_frames,
		clips[1].timeline_start_frame,
		clips[1].source_length_frames,
	)
	tl_probe_check(
		clips[0].clip_id != clips[1].clip_id,
		"the two halves must not share a clip_id (%d == %d)",
		clips[0].clip_id,
		clips[1].clip_id,
	)
	// The right half reads the source after the removed span.
	tl_probe_check(
		clips[1].source_start_frame == 150,
		"right half must start at source frame 150 (got %d)",
		clips[1].source_start_frame,
	)
}

// tl_split_scene: one clip, two keyframe tracks and two markers, so the split
// has something to divide.
tl_split_scene :: proc() {
	tl_straddle_scene()
	cl := &timeline.tracks[0].clips[0]
	cl.source_start_frame = 100
	cl.keyframe_tracks = Kf_Track_Range{}
	session_trk_push(&cl.keyframe_tracks, Kf_Track {
		name = session_str_intern("transform.x"),
		keys = Kf_Keys_Range{},
	})
	track := session_trk_view_mut(&cl.keyframe_tracks, 0)
	session_kf_push(&track.keys, Keyframe{frame_off=50,value=0.0})
	session_kf_push(&track.keys, Keyframe{frame_off=250,value=1.0})
	// Markers are keyed by SOURCE frame. The clip starts at source 100 and the
	// cut is 200 frames in, so the halves read source [100,300) and [300,500):
	// one marker each, which is what makes the label-ownership check possible.
	session_marker_push(&cl.markers, Clip_Marker{source_frame = 150, label = session_str_intern("m-a")})
	session_marker_push(&cl.markers, Clip_Marker{source_frame = 350, label = session_str_intern("m-b")})
	selection.track = 0
	selection.index = 0
	playhead.frame = 200
}

// test_split_halves_own_their_payload pins clip identity plus COW isolation for
// interned names, marker ranges and keyframe ranges.
test_split_halves_own_their_payload :: proc() {
	tl_split_scene()
	split_clip_at_playhead()
	clips := timeline.tracks[0].clips
	tl_probe_check(
		len(clips) == 2,
		"split must leave 2 clips (got %d)",
		len(clips),
	)
	if len(clips) != 2 {
		return
	}
	left, right := &clips[0], &clips[1]
	tl_probe_check(
		left.clip_id != right.clip_id,
		"the halves must not share a clip_id (%d == %d)",
		left.clip_id,
		right.clip_id,
	)
	// Both halves SHARE the one name handle now: the pool is immutable and
	// session-owned, so the split's struct copy copied the handle and nothing owns
	// a second string (TODO.md Active 19). Pointer inequality no longer describes
	// the invariant -- isolation does. Renaming one half must not reach the other,
	// which is the property separate heap ownership used to have to buy.
	orig_name := clip_name(right)
	clip_set_name(left, "renamed-left")
	tl_probe_check(
		clip_name(left) == "renamed-left",
		"renaming the left half did not take (%q)",
		clip_name(left),
	)
	tl_probe_check(
		clip_name(right) == orig_name,
		"renaming the left half reached the right half (%q, was %q)",
		clip_name(right),
		orig_name,
	)
	tl_probe_check(
		left.keyframe_tracks.n == 1 &&
		right.keyframe_tracks.n == 1 &&
		session_trk_view(left.keyframe_tracks,0)^.keys.n == 1 &&
		session_trk_view(right.keyframe_tracks,0)^.keys.n == 1,
		"each half must own one lane with one key (got %d/%d lanes, %d/%d keys)",
		left.keyframe_tracks.n,
		right.keyframe_tracks.n,
		session_trk_view(left.keyframe_tracks,0)^.keys.n,
		session_trk_view(right.keyframe_tracks,0)^.keys.n,
	)
	tl_probe_check(
		session_kf_at(session_trk_view(left.keyframe_tracks,0)^.keys,0).frame_off == 50 &&
			session_kf_at(session_trk_view(right.keyframe_tracks,0)^.keys,0).frame_off == 50,
		"the split's slice-1 rule: keys re-relativized by -left_len (got %d, %d)",
		session_kf_at(session_trk_view(left.keyframe_tracks,0)^.keys,0).frame_off,
		session_kf_at(session_trk_view(right.keyframe_tracks,0)^.keys,0).frame_off,
	)
	// Marker ranges share until a label write triggers marker-list COW.
	tl_probe_check(
		left.markers.n == 1 && right.markers.n == 1,
		"each half must keep one marker (got %d/%d markers)",
		left.markers.n,
		right.markers.n,
	)
	if left.markers.n == 1 && right.markers.n == 1 {
		right_marker := session_marker_at(right.markers, 0)
		orig_label := marker_label(&right_marker)
		marker_set_label(clip_marker_mut(left, 0), "renamed-marker")
		left_marker := session_marker_at(left.markers, 0)
		right_marker = session_marker_at(right.markers, 0)
		tl_probe_check(
			marker_label(&left_marker) == "renamed-marker" &&
			marker_label(&right_marker) == orig_label,
			"renaming the left marker reached the right one (%q, was %q)",
			marker_label(&right_marker),
			orig_label,
		)
	}
	// Editing one half must not disturb the other: the shared-backing failure
	// mode was invisible until teardown.
	kf_geom_set_value(right, "transform.x", 50, 0.75)
	vk := session_kf_view(session_trk_view(left.keyframe_tracks,0)^.keys); v,_ := kf_lane_value(vk[0], 0)
	tl_probe_check(
		v != 0.75,
		"a keyframe edit on the right half wrote through to the left (left lane reads %v)",
		v,
	)
}

test_clip_visible_half_open :: proc() {
	start, length: i64 = 100, 24

	tl_probe_check(
		!clip_visible_at(start - 1, start, length),
		"frame %d is before start %d and must not be visible",
		start - 1,
		start,
	)
	tl_probe_check(
		clip_visible_at(start, start, length),
		"frame %d is at start and must be visible",
		start,
	)
	tl_probe_check(
		clip_visible_at(start + length - 1, start, length),
		"frame %d is the last frame and must be visible",
		start + length - 1,
	)
	tl_probe_check(
		!clip_visible_at(start + length, start, length),
		"frame %d is at end %d and must NOT be visible (half-open upper bound)",
		start + length,
		start + length,
	)
	// A zero-length clip occupies no frames. Splitting at the very first frame
	// can leave one behind, so an accidental >= here would show it for exactly
	// one frame and every other case above would still pass.
	tl_probe_check(
		!clip_visible_at(start, start, 0),
		"a zero-length clip must never be visible",
	)
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
	selection.track = -1
	selection.index = -1
	playhead.frame = 0
	timeline_view.start = 0
	clip_move.group_delta = 0
	clear(&clip_move.group_orig)
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
	selection.track = -1
	selection.index = -1
	timeline_view.start = 0
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
	selection.track = 2
	selection.index = 0
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
		selection.track == 0 && selection.index == 0,
		"selection should move to the cut clip, got (%d,%d)",
		selection.track,
		selection.index,
	)
}

// test_cut_selection_straddle: when the SELECTED clip straddles the playhead,
// S keeps cutting the selection (and its linked partner) exactly as before.
test_cut_selection_straddle :: proc() {
	selection.track = 0
	selection.index = 0
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
			clip_move.clip = &timeline.tracks[0].clips[0]
			if clip_move.clip.timeline_start_frame != clip_move.group_orig[0].start + delta {
				clip_move.clip.timeline_start_frame = clip_move.group_orig[0].start + delta
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
	clip_move.clip = &timeline.tracks[0].clips[0]
	clip_move.clip.timeline_start_frame = 10
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
	clip_move.clip = &timeline.tracks[0].clips[0]
	clip_move.clip.timeline_start_frame = clip_move.group_orig[0].start + 0
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
	clip_move.clip = &timeline.tracks[0].clips[0]
	clip_move.clip.timeline_start_frame = clip_move.group_orig[0].start + -30
	apply_group_drag_to_members(-30)
	v, a = tl_group_starts()
	tl_probe_check(v == 70 && a == 70, "leftward move keeps the pair aligned (V@%d A@%d)", v, a)
}

// test_vertical_drop_alignment: a vertical group drop commits every member at
// m.start + clip_move.group_delta on its destination lane, all still linked+aligned.
test_vertical_drop_alignment :: proc() {
	capture_link_group(&timeline.tracks[0].clips[0], 0)
	clip_move.group_delta = 40
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

test_adjacent_seam_roll :: proc() {
	clear(&media_bin.assets)
	append(&media_bin.assets, Media_Asset{id=8101, kind=.Video, frame_count=200})
	append(&media_bin.assets, Media_Asset{id=8102, kind=.Video, frame_count=100})
	timeline = Timeline{tracks=make([dynamic]Track, 1)}
	timeline.tracks[0].clips = make([dynamic]Clip, 0, 2)
	left := mk_tl_clip(8101, 0, 0, 20, 0, .Video)
	left.asset_id = 8101
	left.source_start_frame = 160
	right := mk_tl_clip(8102, 0, 10, 60, 20, .Video)
	right.asset_id = 8102
	right.source_start_frame = 10
	append(&timeline.tracks[0].clips, left)
	append(&timeline.tracks[0].clips, right)
	select_clip(0, 0)
	selection.extra_set[right.clip_id] = true

	li, ri, paired := timeline_resize_pair_for_edge(0, 0, .Right)
	tl_probe_check(paired && li == 0 && ri == 1, "selected right edge resolves touching pair")
	li, ri, paired = timeline_resize_pair_for_edge(0, 1, .Left)
	tl_probe_check(paired && li == 0 && ri == 1, "selected left edge resolves same touching pair")
	delete_key(&selection.extra_set, right.clip_id)
	_, _, paired = timeline_resize_pair_for_edge(0, 0, .Right)
	tl_probe_check(!paired, "a seam is not paired when neighbor is not selected")
	selection.extra_set[right.clip_id] = true

	seam := resize_clip_seam(&timeline.tracks[0], 0, 1, 30)
	lc, rc := timeline.tracks[0].clips[0], timeline.tracks[0].clips[1]
	tl_probe_check(seam == 30 && clip_timeline_end(lc) == 30 && rc.timeline_start_frame == 30,
		"rightward roll moves both handles +10 to seam 30")
	tl_probe_check(lc.source_start_frame+lc.source_length_frames == 190 &&
		rc.source_start_frame == 20 && rc.source_length_frames == 50 &&
		rc.timeline_start_frame+rc.source_length_frames == 80,
		"rightward roll preserves source tails")

	// Right clip cannot reveal source frames before frame 0.
	seam = resize_clip_seam(&timeline.tracks[0], 0, 1, 0)
	lc, rc = timeline.tracks[0].clips[0], timeline.tracks[0].clips[1]
	tl_probe_check(seam == 10 && clip_timeline_end(lc) == 10 && rc.timeline_start_frame == 10,
		"leftward roll clamps at right source's first frame")
	tl_probe_check(rc.source_start_frame == 0 && rc.source_length_frames == 70,
		"leftward roll keeps right source start at zero")

	// Left clip cannot extend past its source's last frame.
	seam = resize_clip_seam(&timeline.tracks[0], 0, 1, 999)
	lc, rc = timeline.tracks[0].clips[0], timeline.tracks[0].clips[1]
	tl_probe_check(seam == 40 && lc.source_start_frame+lc.source_length_frames == 200,
		"rightward roll clamps at left source's last frame")
	tl_probe_check(rc.timeline_start_frame == 40 && rc.source_start_frame == 30 &&
		rc.source_length_frames == 40 && rc.timeline_start_frame+rc.source_length_frames == 80,
		"paired roll preserves right tail and adjacency")

	// A wider source interval reaches both one-frame endpoints: left cannot
	// collapse to zero, and right cannot collapse to zero either.
	clear(&media_bin.assets)
	append(&media_bin.assets, Media_Asset{id=8103, kind=.Video, frame_count=1000})
	append(&media_bin.assets, Media_Asset{id=8104, kind=.Video, frame_count=100})
	clear(&timeline.tracks[0].clips)
	left = mk_tl_clip(8103, 0, 0, 20, 0, .Video)
	left.asset_id = 8103
	right = mk_tl_clip(8104, 0, 19, 10, 20, .Video)
	right.asset_id = 8104
	right.source_start_frame = 19
	append(&timeline.tracks[0].clips, left)
	append(&timeline.tracks[0].clips, right)
	select_clip(0, 0)
	selection.extra_set[timeline.tracks[0].clips[1].clip_id] = true
	seam = resize_clip_seam(&timeline.tracks[0], 0, 1, 0)
	lc, rc = timeline.tracks[0].clips[0], timeline.tracks[0].clips[1]
	tl_probe_check(seam == 1 && lc.source_length_frames == 1 &&
		rc.source_start_frame == 0 && rc.source_length_frames == 29,
		"roll lower clamp: seam=%d left_len=%d right_start=%d right_len=%d",
		seam, lc.source_length_frames, rc.source_start_frame, rc.source_length_frames)
	seam = resize_clip_seam(&timeline.tracks[0], 0, 1, 999)
	lc, rc = timeline.tracks[0].clips[0], timeline.tracks[0].clips[1]
	tl_probe_check(seam == 29 && lc.source_length_frames == 29 &&
		rc.source_length_frames == 1 && rc.timeline_start_frame+rc.source_length_frames == 30,
		"roll clamps at right's last frame and keeps right nonempty")
	clear(&selection.extra_set)
	clear(&media_bin.assets)
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
	timeline_view.start = 200
	playhead.frame = 300
	ripple_delete_region(100, 50)
	tl_probe_check(
		playhead.frame == 250 && timeline_view.start == 150,
		"view-pan after-region: want ph 250 view 150, got ph %d view %.0f",
		playhead.frame,
		timeline_view.start,
	)

	// Before the region: the playhead doesn't move, so the view doesn't pan.
	tl_single_clip_scene(200, 50)
	timeline_view.start = 200
	playhead.frame = 50
	ripple_delete_region(100, 50)
	tl_probe_check(
		playhead.frame == 50 && timeline_view.start == 200,
		"view-pan before-region: want ph 50 view 200, got ph %d view %.0f",
		playhead.frame,
		timeline_view.start,
	)

	// Linked group: playhead follows the selected member's span.
	timeline = Timeline {
		tracks = make([dynamic]Track, 0, 2, context.temp_allocator),
	}
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 4, context.temp_allocator)})
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 4, context.temp_allocator)})
	append(&timeline.tracks[0].clips, mk_tl_clip(3101, 777, 0, 50, 200, .Video))
	append(&timeline.tracks[1].clips, mk_tl_clip(3102, 777, 0, 50, 200, .Audio))
	selection.track = 0
	selection.index = 0
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
	selection.track = 0
	selection.index = 0

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

// test_audio_resize_source_bound: an audio clip's source bound is the asset's
// audio_frames, not its video frame_count. An audio-only import has no video
// stream, so frame_count falls back to 1; capping on that locked the clip to a
// single frame. The audio lane grows to its real duration and can regrow after
// a shrink, while a video clip on a video asset still caps at frame_count.
test_audio_resize_source_bound :: proc() {
	clear(&media_bin.assets)
	append(&media_bin.assets, Media_Asset{id = 7001, kind = .Audio, frame_count = 1, audio_frames = 500})
	timeline = Timeline {
		tracks = make([dynamic]Track, 0, 1, context.temp_allocator),
	}
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 2, context.temp_allocator)})
	ac := mk_tl_clip(7001, 0, 0, 100, 0, .Audio)
	ac.asset_id = 7001
	append(&timeline.tracks[0].clips, ac)

	got := resize_clip_right(&timeline.tracks[0], 0, 400)
	tl_probe_check(got == 400, "audio resize right: want 400, got %d", got)

	// Still bounded by the real audio length, not unbounded.
	got = resize_clip_right(&timeline.tracks[0], 0, 9999)
	tl_probe_check(got == 500, "audio resize right cap: want 500, got %d", got)

	// Shrink then regrow: the bug locked it at one frame, so this must recover.
	got = resize_clip_right(&timeline.tracks[0], 0, 250)
	tl_probe_check(got == 250, "audio resize shrink: want 250, got %d", got)
	got = resize_clip_right(&timeline.tracks[0], 0, 480)
	tl_probe_check(got == 480, "audio resize regrow: want 480, got %d", got)

	// A video lane on a video asset still caps at frame_count.
	clear(&media_bin.assets)
	append(&media_bin.assets, Media_Asset{id = 7002, kind = .Video, frame_count = 300, audio_frames = 500})
	timeline.tracks[0].clips = nil
	vc := mk_tl_clip(7002, 0, 0, 100, 0, .Video)
	vc.asset_id = 7002
	append(&timeline.tracks[0].clips, vc)
	got = resize_clip_right(&timeline.tracks[0], 0, 9999)
	tl_probe_check(got == 300, "video resize right cap: want 300, got %d", got)

	clear(&media_bin.assets)
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
	test_adjacent_seam_roll()
	fmt.println("[tl-probe] adjacent seam roll ok")

	test_still_resize_free()
	fmt.println("[tl-probe] still-resize ok")

	test_audio_resize_source_bound()
	fmt.println("[tl-probe] audio-resize ok")

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

	test_clip_visible_half_open()
	fmt.println("[tl-probe] clip-visible-half-open ok")

	tl_ripple_dispatch_scene()
	test_ripple_dispatch_closes_gap()
	fmt.println("[tl-probe] ripple-dispatch ok")

	tl_straddle_scene()
	test_ripple_straddle_splits_once()
	fmt.println("[tl-probe] ripple-straddle ok")

	tl_split_scene()
	test_split_halves_own_their_payload()
	fmt.println("[tl-probe] split-ownership ok")

	if tl_probe_fail {
		fmt.println("[tl-probe] FAILED")
		os.exit(1)
	}
	fmt.println("[tl-probe] all checks passed")
	os.exit(0)
}

// drag_probe_run (VYPER_DRAG_PROBE) replays a FAST same-lane flick through the
// LIVE drag model (drag_move_in_place -> clip_slide_in_track) to prove the
// model itself can never "cut short": large per-frame cursor-jump targets must
// park the clip FLUSH against its neighbor, never a few frames before it. The
// historic symptom (clip stops mid-stroke when the cursor flees the clip)
// lived in the caller's lane gate; the model must be lane- and speed-blind.
drag_probe_run :: proc(seed: string) {
	editor_flags.snap_clips_to_playhead = true
	timeline_view.zoom = 1.0

	drag_scene :: proc() {
		timeline = Timeline {
			tracks = make([dynamic]Track, 0, 1, context.temp_allocator),
		}
		append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 2, context.temp_allocator)})
		append(&timeline.tracks[0].clips, mk_tl_clip(7001, 0, 50, 100, 50, .Video))    // dragged
		append(&timeline.tracks[0].clips, mk_tl_clip(7002, 0, 500, 100, 500, .Video))  // right neighbor
		clip_move.clip = &timeline.tracks[0].clips[0]
		clip_move.source_track = 0
		clip_move.source_index = 0
		clip_move.hover_track = 0
		clear(&clip_move.group_orig)
		playhead.frame = 250
	}

	// Case 1: violent rightward flick (up to 250 frames per poll), playhead parked
	// inside the band but far from the flush line. Must park flush at 400.
	drag_scene()
	drag_move_in_place(f32(60))
	drag_move_in_place(f32(161))
	drag_move_in_place(f32(330))
	drag_move_in_place(f32(401))
	drag_move_in_place(f32(520))
	drag_move_in_place(f32(700))
	tl_probe_check(
		clip_move.clip.timeline_start_frame == 400,
		"fast rightward flick parked %d, want 400 (flush with neighbor@500, len 100)",
		clip_move.clip.timeline_start_frame,
	)

	// Case 2: pointer resting mid-gap must track EXACTLY (no truncation lag).
	drag_scene()
	drag_move_in_place(f32(234))
	tl_probe_check(
		clip_move.clip.timeline_start_frame == 234,
		"mid-gap target parked %d, want 234",
		clip_move.clip.timeline_start_frame,
	)

	// Case 3: live-follow must continue even while the pointer rests in a DIFFERENT
	// lane (the model is lane-blind; hover only picks the ghost/drop target).
	drag_scene()
	clip_move.hover_track = 1
	drag_move_in_place(f32(330))
	drag_move_in_place(f32(520))
	tl_probe_check(
		clip_move.clip.timeline_start_frame == 400,
		"cross-lane flick parked %d, want 400 (flush)",
		clip_move.clip.timeline_start_frame,
	)

	// Case 4: leftward from a position already FLUSH against a left neighbor
	// (packed timeline): the neighbor's body sits between the clip and the
	// leftward free zone, so the slide is legitimately blocked and must stay
	// pinned at the flush line — never slide onto/over the neighbor.
	timeline = Timeline {
		tracks = make([dynamic]Track, 0, 1, context.temp_allocator),
	}
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 2, context.temp_allocator)})
	append(&timeline.tracks[0].clips, mk_tl_clip(7003, 0, 300, 100, 300, .Video))  // left neighbor covers [300,400)
	append(&timeline.tracks[0].clips, mk_tl_clip(7004, 0, 400, 100, 400, .Video))  // dragged, flush at 400
	clip_move.clip = &timeline.tracks[0].clips[1]
	clip_move.source_track = 0
	clip_move.source_index = 1
	clip_move.hover_track = 0
	clear(&clip_move.group_orig)
	playhead.frame = 250
	drag_move_in_place(f32(380))
	drag_move_in_place(f32(260))
	drag_move_in_place(f32(120))
	drag_move_in_place(f32(10))
	tl_probe_check(
		clip_move.clip.timeline_start_frame == 400,
		"leftward from flush-against-left-neighbor slipped to %d, want 400 (blocked; neighbor body in the way)",
		clip_move.clip.timeline_start_frame,
	)

	// Case 4b: leftward APPROACH toward a left neighbor (clip starts right of a
	// gap) must park FLUSH against the neighbor's end.
	timeline = Timeline {
		tracks = make([dynamic]Track, 0, 1, context.temp_allocator),
	}
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 2, context.temp_allocator)})
	append(&timeline.tracks[0].clips, mk_tl_clip(7008, 0, 300, 100, 300, .Video))  // left neighbor covers [300,400)
	append(&timeline.tracks[0].clips, mk_tl_clip(7009, 0, 450, 100, 450, .Video))  // dragged, in gap [400,..)
	clip_move.clip = &timeline.tracks[0].clips[1]
	clip_move.source_track = 0
	clip_move.source_index = 1
	clip_move.hover_track = 0
	clear(&clip_move.group_orig)
	playhead.frame = 250
	drag_move_in_place(f32(430))
	drag_move_in_place(f32(410))
	drag_move_in_place(f32(395))
	drag_move_in_place(f32(300))
	tl_probe_check(
		clip_move.clip.timeline_start_frame == 400,
		"leftward approach parked %d, want 400 (flush with left neighbour end)",
		clip_move.clip.timeline_start_frame,
	)

	// Case 5: packed timeline (dragged clip already flush against a LEFT
	// neighbor), fast RIGHTWARD approach toward a right neighbor. Must park
	// flush against the RIGHT neighbor — and must NOT let the boundary union
	// throw the clip into the left neighbor's band.
	timeline = Timeline {
		tracks = make([dynamic]Track, 0, 1, context.temp_allocator),
	}
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 3, context.temp_allocator)})
	append(&timeline.tracks[0].clips, mk_tl_clip(7005, 0, 0, 100, 0, .Video))
	append(&timeline.tracks[0].clips, mk_tl_clip(7006, 0, 100, 100, 100, .Video))
	append(&timeline.tracks[0].clips, mk_tl_clip(7007, 0, 320, 100, 320, .Video))
	clip_move.clip = &timeline.tracks[0].clips[1]
	clip_move.source_track = 0
	clip_move.source_index = 1
	clip_move.hover_track = 0
	clear(&clip_move.group_orig)
	playhead.frame = 250
	drag_move_in_place(f32(130))
	drag_move_in_place(f32(240))
	drag_move_in_place(f32(310))
	drag_move_in_place(f32(450))
	drag_move_in_place(f32(620))
	tl_probe_check(
		clip_move.clip.timeline_start_frame == 220,
		"packed rightward approach parked %d, want 220 (flush with right neighbor@320)",
		clip_move.clip.timeline_start_frame,
	)

	// Case 6: the traced STALL — a linked group flicked LEFT with a member
	// blocked on its own lane, cursor target jumping WELL past the blocker in
	// one frame. The old feasibility gate froze the whole group at the last
	// sampled target (anchor mid-band, "cut short"); the delta clamp must park
	// the group FLUSH against the binding member's blocker instead.
	timeline = Timeline {
		tracks = make([dynamic]Track, 0, 2, context.temp_allocator),
	}
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 2, context.temp_allocator)})
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 2, context.temp_allocator)})
	append(&timeline.tracks[0].clips, mk_tl_clip(1001, 9003, 100, 50, 100, .Video))
	append(&timeline.tracks[1].clips, mk_tl_clip(1002, 9003, 100, 50, 100, .Audio))
	append(&timeline.tracks[1].clips, mk_tl_clip(6003, 0, 25, 40, 25, .Audio)) // blocker [25,65)
	capture_link_group(&timeline.tracks[0].clips[0], 0)
	clip_move.clip = &timeline.tracks[0].clips[0]
	clip_move.source_track = 0
	clip_move.source_index = 0
	clip_move.hover_track = 0
	// One violent left flick to frame 50 (delta -50, lands the audio member
	// ON the blocker). Clamp must park BOTH at 65 (delta -35, flush right of
	// X's end), not freeze the anchor at 100.
	drag_move_in_place(f32(50))
	v, a := tl_group_starts()
	tl_probe_check(
		v == 65 && a == 65,
		"fast left group flick over a member blocker parked V@%d A@%d, want 65/65 (flush right of blocker end)",
		v,
		a,
	)

	if tl_probe_fail {
		fmt.println("[drag-probe] FAILED")
		os.exit(1)
	}
	fmt.println("[drag-probe] all checks passed")
	os.exit(0)
}
