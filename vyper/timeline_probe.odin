package vyper

import "core:fmt"
import "core:math"
import "core:os"
import sdl "vendor:sdl3"
import "core:strings"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

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
		// Isolation, not a count. This scene splits MID-INTERPOLATION (keys at 50 and
		// 250, cut at 200), so the left half legitimately ends up holding its own
		// pre-cut key AND the boundary key that carries the curve's value at the cut
		// (kf_split_preserve_continuity). What this test is actually about is that
		// the halves do not SHARE a key range: each writes its own copy. Asserting a
		// fixed count here would fail the moment the boundary key is correct, which
		// is why it counts "both lanes present and distinct" instead.
		tl_probe_check(
			left.keyframe_tracks.n == 1 &&
			right.keyframe_tracks.n == 1 &&
			session_trk_view(left.keyframe_tracks,0)^.keys.n >= 1 &&
			session_trk_view(right.keyframe_tracks,0)^.keys.n >= 1,
			"each half must own its own lane with at least one key (got %d/%d lanes, %d/%d keys)",
			left.keyframe_tracks.n,
			right.keyframe_tracks.n,
			session_trk_view(left.keyframe_tracks,0)^.keys.n,
			session_trk_view(right.keyframe_tracks,0)^.keys.n,
		)
		// And the two key ranges must be distinct objects, not one shared range
		// reached through two clips.
		if left.keyframe_tracks.n == 1 && right.keyframe_tracks.n == 1 {
			lk := session_trk_view(left.keyframe_tracks,0)^.keys
			rk := session_trk_view(right.keyframe_tracks,0)^.keys
			tl_probe_check(
				lk != rk,
				"the two halves must not share one key range (both at %v)",
				lk,
			)
		}
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

	// The playhead→clip snap must land on a frame the clip OWNS. A clip spans
	// [start, start+length) (clip_visible_at is half-open), so the end boundary is
	// one frame PAST the last content frame. The old snap targeted that boundary,
	// which showed the NEXT clip's first frame whenever clips were contiguous and
	// merely looked fine when a gap followed.
	//
	// The case that isolates it is a clip with a GAP after it: only its own end edge
	// is in range, so whatever comes back is unambiguously that edge. Contiguous
	// clips are deliberately NOT the primary case — at a seam the next clip's start is
	// also a candidate and nearest-edge legitimately prefers it. That is the rule
	// working, not the bug, and a probe asserting 99 there asserts the wrong thing
	// (it did, until the resolver was run against it).
	test_snap_playhead_end_lands_inside_the_clip :: proc() {
		timeline.tracks = make([dynamic]Track, 0, 1, context.temp_allocator)
		append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 4, context.temp_allocator)})
		// [0,100), a gap, then [200,300). Near frame 101 only clip 0's END edge is in
		// range; clip 1's start (200) is far outside the margin.
		append(&timeline.tracks[0].clips, mk_tl_clip(9101, 0, 0, 100, 0, .Video))
		append(&timeline.tracks[0].clips, mk_tl_clip(9102, 0, 0, 100, 200, .Video))
		timeline_view.zoom = 1
		timeline_view.start = 0

		got := snap_playhead_to_clip_edge(101)
		tl_probe_check(got == 99, "snapping near a lone clip's end must land on 99 (its last frame), got %d", got)
		tl_probe_check(
			clip_visible_at(got, 0, 100),
			"the snapped frame %d must be a frame the clip owns",
			got,
		)
		// The reported symptom in one line: never the frame past the end.
		tl_probe_check(got != 100, "the snap must not land on the exclusive end (100)")

		// From inside the clip, near its end: still its last frame, never past it.
		got_in := snap_playhead_to_clip_edge(97)
		tl_probe_check(got_in == 99, "snapping from inside near the end must land on 99, got %d", got_in)

		// A start edge is untouched: frame 200 is clip 1's start and snaps to itself.
		tl_probe_check(
			snap_playhead_to_clip_edge(200) == 200,
			"a start edge must still snap to itself, got %d",
			snap_playhead_to_clip_edge(200),
		)

		// The final clip's end must not park the playhead in the sheet-empty slot
		// past all content: duration is 300, so 299 is the last real frame.
		got3 := snap_playhead_to_clip_edge(299)
		tl_probe_check(got3 == 299, "snapping the final clip's end must land on 299, got %d", got3)
		tl_probe_check(
			got3 <= timeline_duration() - 1,
			"the snap must stay inside the timeline (%d > %d)",
			got3,
			timeline_duration() - 1,
		)

		// Beyond the margin the frame comes back untouched: this is a latch, not a
		// magnet.
		tl_probe_check(
			snap_playhead_to_clip_edge(50) == 50,
			"a frame far from every edge must not move",
		)
		tl_probe_check(
			snap_playhead_to_clip_edge(150) == 150,
			"a frame in the gap between clips must not move",
		)

		// A zero-length clip owns no end frame, so its end folds onto its start rather
		// than pointing one frame BEFORE it. Placed mid-timeline so the duration clamp
		// cannot be what answers: a zero-length clip AT the duration boundary makes
		// clip_timeline_end == duration, and the clamp then masks the fold entirely.
		append(&timeline.tracks[0].clips, mk_tl_clip(9103, 0, 0, 0, 150, .Video))
		got_zero := snap_playhead_to_clip_edge(150)
		tl_probe_check(
			got_zero == 150,
			"a zero-length clip's end must fold onto its start, got %d",
			got_zero,
		)
		tl_probe_check(
			got_zero >= timeline.tracks[0].clips[2].timeline_start_frame,
			"the fold must never point before the clip's own start (%d)",
			got_zero,
		)
	}

	// The clip→playhead direction is the other half of the toggle pair and shares
	// nothing with the resolver above, so it is pinned here too: a clip drag must
	// latch onto the playhead, and the margin must be exactly SNAP_PIXELS wide at
	// any zoom (the old max(..,1) floor let it balloon when zoomed out).
	test_snap_to_playhead_margin_scales_with_zoom :: proc() {
		tl_scene()
		playhead.frame = 100
		timeline_view.zoom = 1
		timeline_view.start = 0
		// SNAP_PIXELS = 8 at zoom 1 -> within 8 frames latches, 9 does not.
		tl_probe_check(snap_to_playhead(108) == 100, "8 frames from the playhead must latch")
		tl_probe_check(snap_to_playhead(109) == 109, "9 frames away is outside the margin and must not latch")
		// The margin is in pixels, so zooming out keeps the same on-screen band.
		timeline_view.zoom = 0.01
		tl_probe_check(
			snap_to_playhead(900) == 100,
			"the snap band stays 8px wide at zoom 0.01",
		)
		tl_probe_check(
			snap_to_playhead(901) == 901,
			"just past the band at zoom 0.01 must not latch",
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

	// tl_ripple_scene builds the Alt+drag scene. Two lanes, laid out left to right,
	// with every clip on a distinct id so a test can name what moved and what must
	// not have:
	//
	//	track 0: 8100 [0,50)   8200 [100,150)  8300 [200,250)  8400 [300,350)  8500 [400,450)
	//	track 1: 7100 [0,40)   7200 [50,90)                              7300 [100,140)  7400 [200,240)
	//
	// The anchor is 8200 (track 0, start 100), so the threshold is 100 and the
	// ripple is everything at or after it PLUS 7200, which starts at 50 and is only
	// in the set because it shares the anchor's link. 8100 and 7100 start before
	// the threshold and are in no group, so they are the two clips that must hold
	// still and the two walls a leftward ripple parks against.
	tl_ripple_scene :: proc() {
		timeline = Timeline {
			tracks = make([dynamic]Track, 0, 2, context.temp_allocator),
		}
		append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 6, context.temp_allocator)})
		append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 4, context.temp_allocator)})
		append(&timeline.tracks[0].clips, mk_tl_clip(8100, 0, 0, 50, 0, .Video))
		append(&timeline.tracks[0].clips, mk_tl_clip(8200, 8800, 0, 50, 100, .Video))
		append(&timeline.tracks[0].clips, mk_tl_clip(8300, 0, 0, 50, 200, .Video))
		append(&timeline.tracks[0].clips, mk_tl_clip(8400, 0, 0, 50, 300, .Video))
		append(&timeline.tracks[0].clips, mk_tl_clip(8500, 0, 0, 50, 400, .Video))
		append(&timeline.tracks[1].clips, mk_tl_clip(7100, 0, 0, 40, 0, .Audio))
		append(&timeline.tracks[1].clips, mk_tl_clip(7200, 8800, 0, 40, 50, .Audio))
		append(&timeline.tracks[1].clips, mk_tl_clip(7300, 0, 0, 40, 100, .Audio))
		append(&timeline.tracks[1].clips, mk_tl_clip(7400, 0, 0, 40, 200, .Audio))
		selection.track = 0
		selection.index = 1
		// clear, not make: extra_set is a process-lifetime global in the app and the
		// Shift+click path resets it the same way. A fresh map on context.allocator
		// per scene would orphan one map per call for no reason.
		clear(&selection.extra_set)
		timeline_view.start = 0
		clip_move.group_delta = 0
		clear(&clip_move.group_orig)
		clip_move.ripple = false
		clip_move.ripple_delta = 0
		clear(&clip_move.ripple_orig)
		active_interaction = .None
	}

	// tl_start_of returns the live timeline start of the clip with the given id.
	tl_start_of :: proc(cid: u64) -> i64 {
		for &tr in timeline.tracks {
			for &c in tr.clips {
				if c.clip_id == cid {
					return c.timeline_start_frame
				}
			}
		}
		return -1
	}

	// Ripple_Want is one expected (clip id, timeline start) pair in a table.
	Ripple_Want :: struct {
		clip_id: u64,
		start:   i64,
	}

	// tl_assert_starts checks a whole clip->start table, so a failure names every
	// clip that landed wrong rather than only the first.
	tl_assert_starts :: proc(what: string, want: ..Ripple_Want) {
		for w in want {
			got := tl_start_of(w.clip_id)
			tl_probe_check(
				got == w.start,
				"%s: clip %d at %d, want %d",
				what,
				w.clip_id,
				got,
				w.start,
			)
		}
	}

	// tl_spans records every clip's [start, end) BEFORE the drag. Both halves of
	// each compared pair are looked up, because "did this pair overlap before" is a
	// fact about the PAIR: recording only one side would let a pre-existing overlap
	// look newly created (and the straddler case is exactly that).
	tl_spans :: proc() -> map[u64][2]i64 {
		out := make(map[u64][2]i64, context.temp_allocator)
		for &tr in timeline.tracks {
			for &c in tr.clips {
				out[c.clip_id] = [2]i64{c.timeline_start_frame, c.timeline_start_frame + c.source_length_frames}
			}
		}
		return out
	}

	// tl_assert_no_new_overlap fails if any same-lane pair overlaps NOW that did not
	// overlap in `before`. This is the property the whole ripple rests on: every
	// member shifts by the SAME delta, so relative geometry inside the set is
	// preserved and the only possible new collision is member-vs-non-member.
	tl_assert_no_new_overlap :: proc(before: map[u64][2]i64) {
		for &tr in timeline.tracks {
			for i in 0 ..< len(tr.clips) {
				for j in i + 1 ..< len(tr.clips) {
					a, b := tr.clips[i], tr.clips[j]
					if a.timeline_start_frame >= b.timeline_start_frame + b.source_length_frames ||
					   b.timeline_start_frame >= a.timeline_start_frame + a.source_length_frames {
						continue
					}
					wa, oka := before[a.clip_id]
					wb, okb := before[b.clip_id]
					// A clip absent from the snapshot was added after it was taken,
					// so this pair has no "before" to be judged against.
					if !oka || !okb {
						continue
					}
					tl_probe_check(
						wa[0] < wb[1] && wb[0] < wa[1],
						"ripple created an overlap: clip %d [%d,%d) vs clip %d [%d,%d)",
						a.clip_id,
						a.timeline_start_frame,
						a.timeline_start_frame + a.source_length_frames,
						b.clip_id,
						b.timeline_start_frame,
						b.timeline_start_frame + b.source_length_frames,
					)
				}
			}
		}
	}

	// tl_assert_link_offset fails unless every other member of `link` sits the same
	// distance from the anchor as it did at capture. An OFFSET link pair is legal —
	// a partner may start before its anchor — so this, not tl_assert_aligned, is
	// the alignment invariant a ripple must hold: tl_assert_aligned demands equal
	// ABSOLUTE starts and would report a correct ripple as a desync.
	tl_assert_link_offset :: proc(link, anchor_id: u64, want: i64) {
		base := tl_start_of(anchor_id)
		for &tr in timeline.tracks {
			for &c in tr.clips {
				if c.link_id != link || c.clip_id == anchor_id {
					continue
				}
				tl_probe_check(
					c.timeline_start_frame - base == want,
					"link %d: clip %d sits %d from the anchor, want %d",
					link,
					c.clip_id,
					c.timeline_start_frame - base,
					want,
				)
			}
		}
	}

	// test_ripple_set_capture: the captured set is the anchor, its link partner
	// (which starts BEFORE the threshold), and everything at or after the anchor —
	// and nothing else. Anchor-first matters: the delta is measured from
	// ripple_orig[0].start, so a set whose head is not the grabbed clip rips from
	// the wrong frame.
	test_ripple_set_capture :: proc() {
		tl_ripple_scene()
		capture_link_group(&timeline.tracks[0].clips[1], 0)
		capture_ripple_set(&timeline.tracks[0].clips[1], 0)
		tl_probe_check(
			len(clip_move.ripple_orig) == 7,
			"ripple set must hold 7 clips (anchor + link + 5 at/after), got %d",
			len(clip_move.ripple_orig),
		)
		if len(clip_move.ripple_orig) == 0 {
			return
		}
		tl_probe_check(
			clip_move.ripple_orig[0].clip_id == 8200,
			"ripple set head must be the grabbed clip 8200, got %d",
			clip_move.ripple_orig[0].clip_id,
		)
		held_back := []u64{8100, 7100}
		for cid in held_back {
			tl_probe_check(
				!ripple_moves_clip(cid),
				"clip %d starts before the anchor and is in no group: must NOT be in the ripple set",
				cid,
			)
		}
		moving := []u64{8200, 7200, 8300, 8400, 8500, 7300, 7400}
		for cid in moving {
			tl_probe_check(
				ripple_moves_clip(cid),
				"clip %d must be in the ripple set",
				cid,
			)
		}
	}

	// test_ripple_moves_everything_downstream: the whole point of the gesture. One
	// shared delta moves every lane's tail and leaves every head exactly where it
	// was, and the link pair keeps its offset so the A/V glue survives.
	test_ripple_moves_everything_downstream :: proc() {
		tl_ripple_scene()
		before := tl_spans()
		capture_link_group(&timeline.tracks[0].clips[1], 0)
		capture_ripple_set(&timeline.tracks[0].clips[1], 0)
		clip_move.clip = &timeline.tracks[0].clips[1]
		clip_move.source_track = 0
		clip_move.source_index = 1
		clip_move.hover_track = 0
		clip_move.ripple = true
		// frame 130 with the anchor captured at 100 -> delta +30.
		drag_move_in_place(f32(130))
		tl_probe_check(clip_move.ripple_delta == 30, "delta must be +30, got %d", clip_move.ripple_delta)
		tl_assert_starts(
			"ripple +30",
			Ripple_Want{8100, 0},
			Ripple_Want{7100, 0},
			Ripple_Want{8200, 130},
			Ripple_Want{7200, 80},
			Ripple_Want{8300, 230},
			Ripple_Want{8400, 330},
			Ripple_Want{8500, 430},
			Ripple_Want{7300, 130},
			Ripple_Want{7400, 230},
		)
		tl_assert_no_new_overlap(before)
		tl_assert_link_offset(8800, 8200, -50)

		// Dragging back to where it started must land EXACTLY on the original
		// geometry: the apply writes from the captured originals, not from the live
		// position, so a long slide out and back cannot accumulate a frame of drift.
		drag_move_in_place(f32(100))
		tl_assert_starts(
			"ripple back to 0",
			Ripple_Want{8100, 0},
			Ripple_Want{7100, 0},
			Ripple_Want{8200, 100},
			Ripple_Want{7200, 50},
			Ripple_Want{8300, 200},
			Ripple_Want{8400, 300},
			Ripple_Want{8500, 400},
			Ripple_Want{7300, 100},
			Ripple_Want{7400, 200},
		)
		tl_probe_check(clip_move.ripple_delta == 0, "returning home must be delta 0, got %d", clip_move.ripple_delta)
	}

	// test_ripple_clamps_flush_on_one_wall: a leftward ripple is bounded by the
	// tightest non-member tail, and the WHOLE set shifts by that clamped delta. The
	// binding wall here is 7100's tail at 40 against 7200's start at 50, so the set
	// parks at delta -10: 7200 lands flush on 7100, and 8200 stops 40 frames short
	// of 8100 rather than being allowed to drive through it. A per-clip clamp would
	// put 8200 at 50 and 7200 at 40 — the link pair desynced by 10 frames, which is
	// the A/V drift this editor has already been bitten by.
	test_ripple_clamps_flush_on_one_wall :: proc() {
		tl_ripple_scene()
		before := tl_spans()
		capture_link_group(&timeline.tracks[0].clips[1], 0)
		capture_ripple_set(&timeline.tracks[0].clips[1], 0)
		clip_move.clip = &timeline.tracks[0].clips[1]
		clip_move.source_track = 0
		clip_move.source_index = 1
		clip_move.hover_track = 0
		clip_move.ripple = true
		drag_move_in_place(f32(0))
		tl_probe_check(
			clip_move.ripple_delta == -10,
			"leftward ripple must clamp to -10 (7100's tail), got %d",
			clip_move.ripple_delta,
		)
		tl_assert_starts(
			"ripple clamped",
			Ripple_Want{8100, 0},
			Ripple_Want{7100, 0},
			Ripple_Want{8200, 90},
			Ripple_Want{7200, 40},
			Ripple_Want{8300, 190},
			Ripple_Want{8400, 290},
			Ripple_Want{8500, 390},
			Ripple_Want{7300, 90},
			Ripple_Want{7400, 190},
		)
		tl_assert_no_new_overlap(before)
		tl_assert_link_offset(8800, 8200, -50)
		// 7200 is exactly flush against 7100's tail — the wall, not short of it.
		tl_probe_check(
			tl_start_of(7200) == tl_start_of(7100) + 40,
			"the binding member must park flush against its wall (7100@%d 7200@%d)",
			tl_start_of(7100),
			tl_start_of(7200),
		)
	}

	// test_ripple_stops_at_the_left_edge: with nothing but empty timeline to the
	// left, a clip captured at frame 0 bounds the ripple at delta 0. The set cannot
	// shift left past the origin, and it shifts by NOTHING rather than partially.
	test_ripple_stops_at_the_left_edge :: proc() {
		tl_ripple_scene()
		before := tl_spans()
		// Re-lay lane 1 so a member sits at frame 0 with empty timeline before it,
		// which is the only wall that can exist there.
		clear(&timeline.tracks[1].clips)
		append(&timeline.tracks[1].clips, mk_tl_clip(7200, 8800, 0, 40, 0, .Audio))
		append(&timeline.tracks[1].clips, mk_tl_clip(7300, 0, 0, 40, 100, .Audio))
		capture_link_group(&timeline.tracks[0].clips[1], 0)
		capture_ripple_set(&timeline.tracks[0].clips[1], 0)
		clip_move.clip = &timeline.tracks[0].clips[1]
		clip_move.source_track = 0
		clip_move.source_index = 1
		clip_move.hover_track = 0
		clip_move.ripple = true
		drag_move_in_place(f32(10))
		tl_probe_check(
			clip_move.ripple_delta == 0,
			"a member at frame 0 must floor the ripple at delta 0, got %d",
			clip_move.ripple_delta,
		)
		tl_assert_starts("ripple at the left edge", Ripple_Want{7200, 0}, Ripple_Want{8200, 100}, Ripple_Want{8300, 200})
		tl_assert_no_new_overlap(before)
	}

	// test_ripple_carries_the_shift_selection: a clip the user explicitly
	// Shift-clicked into the group joins the ripple even when it starts BEFORE the
	// anchor's threshold, and moves by the shared delta. This is the "select both,
	// alt-drag one" case from the request: without it the other selected clip stays
	// behind and the selection is a lie by the time the drag ends.
	test_ripple_carries_the_shift_selection :: proc() {
		tl_ripple_scene()
		before := tl_spans()
		// 8100 starts at 0, before the threshold of 100, and is in no link group.
		selection.extra_set[8100] = true
		capture_link_group(&timeline.tracks[0].clips[1], 0)
		capture_ripple_set(&timeline.tracks[0].clips[1], 0)
		tl_probe_check(
			ripple_moves_clip(8100),
			"a Shift-clicked clip must join the ripple even when it starts before the anchor",
		)
		clip_move.clip = &timeline.tracks[0].clips[1]
		clip_move.source_track = 0
		clip_move.source_index = 1
		clip_move.hover_track = 0
		clip_move.ripple = true
		drag_move_in_place(f32(120))
		tl_assert_starts(
			"ripple carries the extra",
			Ripple_Want{8100, 20},
			Ripple_Want{7100, 0},
			Ripple_Want{8200, 120},
			Ripple_Want{7200, 70},
			Ripple_Want{8500, 420},
			Ripple_Want{7400, 220},
		)
		tl_assert_no_new_overlap(before)
	}

	// test_ripple_ignores_a_straddler: a clip that already overlaps a member stays
	// where it is and the ripple does not try to resolve the overlap. This timeline
	// permits same-lane overlap for stacked clips, so a straddler is a legitimate
	// state; treating it as a wall would freeze the whole set on the strength of an
	// overlap the user never asked about, and treating it as movable would silently
	// pull a clip the gesture was never scoped to.
	test_ripple_ignores_a_straddler :: proc() {
		tl_ripple_scene()
		// 7150 starts at 20 and runs to 130, so it already overlaps 7300's
		// [100,140) and 7200's [50,90). It must not move, and it must not act as a
		// wall for the rest of the set. Added BEFORE the snapshot, because the
		// overlap it creates is the pre-existing overlap the test is about.
		append(&timeline.tracks[1].clips, mk_tl_clip(7150, 0, 0, 110, 20, .Audio))
		before := tl_spans()
		capture_link_group(&timeline.tracks[0].clips[1], 0)
		capture_ripple_set(&timeline.tracks[0].clips[1], 0)
		tl_probe_check(
			!ripple_moves_clip(7150),
			"a straddler starting before the anchor must not join the ripple set",
		)
		clip_move.clip = &timeline.tracks[0].clips[1]
		clip_move.source_track = 0
		clip_move.source_index = 1
		clip_move.hover_track = 0
		clip_move.ripple = true
		drag_move_in_place(f32(200))
		tl_assert_starts(
			"ripple over a straddler",
			Ripple_Want{7150, 20},
			Ripple_Want{8200, 200},
			Ripple_Want{7200, 150},
			Ripple_Want{7300, 200},
			Ripple_Want{7400, 300},
		)
		tl_assert_no_new_overlap(before)
	}

	// tl_pin_scene builds a one-video-clip project whose asset carries a probed rate
	// and a frame count, so pf_pin_src_fps has something to choose between. A probed
	// rate of 0 is the OLD-project case: frame_count and dur_us present, no rate.
	tl_pin_scene :: proc(probed: f64, frames, dur_us: i64) {
		free_timeline(&timeline)
		clear(&media_bin.assets)
		append(
			&media_bin.assets,
			Media_Asset {
				id = 9001, kind = .Video, frame_count = frames, dur_us = dur_us, video_fps = probed,
			},
		)
		append(&timeline.tracks, Track{})
		tl := &timeline.tracks[0]
		append(&tl.clips, Clip{kind = .Video, asset_id = 9001, source_length_frames = frames})
	}

	// test_pin_src_fps covers the pin that decides a clip's SPEED on load.
	//
	// It exists because a saved project loaded with every clip at the PROJECT's
	// speed — a 12fps source in a 60fps project played 5x too fast, which is the
	// defect conform removes, reproduced exactly. The cause was not the conform: it
	// was Media_Asset.video_fps never being persisted, so every asset arrived at
	// load with no rate and pf_pin_src_fps fell through to the project rate, which
	// is the 1:1 that conform is defined against. A pin that silently degrades to
	// the thing it exists to override is worse than no pin.
	//
	// So the three rungs are asserted separately, and the middle one is the one that
	// was missing: a project saved before the field existed carries frame_count and
	// dur_us but no rate, and must still pin to the source rather than the project.
	test_pin_src_fps :: proc() {
		ok := true
		fail_msg := ""

		saved_rate := project.frame_rate
		saved_tracks := timeline.tracks
		saved_assets := media_bin.assets
		saved_order := timeline.track_order
		defer {
			project.frame_rate = saved_rate
			timeline.tracks = saved_tracks
			media_bin.assets = saved_assets
			timeline.track_order = saved_order
		}

		// Rung 1: the probed rate, when the project has one.
		project.frame_rate = 60.0
		tl_pin_scene(12.0, 219, 18261000)
		pf_pin_src_fps()
		got := timeline.tracks[0].clips[0].src_fps
		if math.abs(got - 12.0) > 0.001 {
			ok = false
			fail_msg = fmt.tprintf("probed rate ignored: pinned %v, want 12", got)
		}

		// Rung 2: an OLD project — frame_count/dur_us, no probed rate. This is the
		// regression: it used to fall through to the project rate (60), which is a
		// ratio of 1 and replays the 12fps source at 5x speed.
		tl_pin_scene(0.0, 219, 18261000)
		pf_pin_src_fps()
		got = timeline.tracks[0].clips[0].src_fps
		derived := 219.0 * 1e6 / 18261000.0
		if math.abs(got - derived) > 0.001 {
			ok = false
			fail_msg = fmt.tprintf("old project pinned %v (project rate would be 60, derived %v)", got, derived)
		}
		// And the thing the user actually saw. Asserted as BEHAVIOUR over one second
		// of playback rather than as a pair of frame indices: one second at 60fps is
		// 60 timeline frames, and one second of a 12fps source is 12 source frames, so
		// the clip must advance 12. A derived rate is 11.9928 rather than 12 (it comes
		// from frame_count/dur_us), which is 0.06% fast, so the tolerance is a
		// fraction of a frame rather than zero — pinning an exact index pair here
		// would be asserting the derived value, not the speed.
		if math.abs(derived - 12.0) / 12.0 > 0.005 {
			ok = false
			fail_msg = fmt.tprintf("derived rate %v is not within 0.5%% of the source's 12", derived)
		}
		advanced := f64(clip_source_frame(0, 0, 60, false, got))
		if math.abs(advanced - 12.0) > 0.2 {
			ok = false
			fail_msg = fmt.tprintf(
				"one second at 60fps advanced %.3f source frames, want 12 — the 5x-too-fast defect",
				advanced,
			)
		}

		// Rung 3: nothing characterisable — the project rate, reproducing 1:1 so a
		// project we cannot measure behaves as it did before.
		tl_pin_scene(0.0, 0, 0)
		pf_pin_src_fps()
		got = timeline.tracks[0].clips[0].src_fps
		if math.abs(got - 60.0) > 0.001 {
			ok = false
			fail_msg = fmt.tprintf("unmeasurable source pinned %v, want the project rate 60", got)
		}

		// An ALREADY-pinned clip is left alone: re-pinning must not move a clip whose
		// rate the file recorded, or every reload would rewrite authored speeds.
		tl_pin_scene(0.0, 219, 18261000)
		timeline.tracks[0].clips[0].src_fps = 24.0
		pf_pin_src_fps()
		got = timeline.tracks[0].clips[0].src_fps
		if math.abs(got - 24.0) > 0.001 {
			ok = false
			fail_msg = fmt.tprintf("re-pin overwrote an authored rate: %v, want 24", got)
		}

		tl_probe_check(ok, "src_fps pin: probed rate, old-project derive, unmeasurable fallback, no re-pin [%s]", fail_msg)
	}


	// tl_fps_scene builds two clips on one track with a real GAP between them, from a
	// 12fps source of 219 frames (18.25s of content) — the shape of ~/baby.vyproj, and
	// the case the user reported as "5 times faster" at 60fps.
	tl_fps_scene :: proc() {
		free_timeline(&timeline)
		clear(&media_bin.assets)
		append(
			&media_bin.assets,
			Media_Asset{id = 9101, kind = .Video, frame_count = 219, dur_us = 18250000, video_fps = 12.0},
		)
		append(&timeline.tracks, Track{})
		tl := &timeline.tracks[0]
		append(
			&tl.clips,
			Clip {
				clip_id = 1, kind = .Video, asset_id = 9101,
				timeline_start_frame = 0, source_length_frames = 219, src_fps = 12.0,
			},
		)
		// Second clip starts 2s (24 frames at 12fps) after the first ends, so a reflow
		// that preserves the GAP is distinguishable from one that pins positions.
		append(
			&tl.clips,
			Clip {
				clip_id = 2, kind = .Video, asset_id = 9101,
				timeline_start_frame = 243, source_length_frames = 219, src_fps = 12.0,
			},
		)
	}

	// test_fps_reflow covers the acceptance criterion directly: the same project must
	// show the same CONTENT at 12fps and at 60fps, at the same speed, differing only
	// in how finely it is sampled.
	//
	// It is stated on wall-clock CONTENT, not on frame counts, because frame counts
	// are exactly what legitimately differs and asserting them would pin the bug back
	// in: at 60fps the clip has five times the frames and must show five times fewer
	// new source frames each.
	test_fps_reflow :: proc() {
		tl_fps_scene()
		saved_rate := project.frame_rate
		defer project.frame_rate = saved_rate

		// Baseline at the source's own rate: 219 frames, 18.25s.
		project.frame_rate = 12.0
		len12 := clip_timeline_len(&timeline.tracks[0].clips[0])
		content12 := f64(clip_src_len_frames(&timeline.tracks[0].clips[0])) / 12.0
		gap12 := f64(
			timeline.tracks[0].clips[1].timeline_start_frame -
			(timeline.tracks[0].clips[0].timeline_start_frame + len12),
		) / 12.0

		// Now the user's case: switch to 60 and reflow, as the preset button does.
		set_project_fps(60)
		c0 := &timeline.tracks[0].clips[0]
		c1 := &timeline.tracks[0].clips[1]
		len60 := clip_timeline_len(c0)
		content60 := f64(clip_src_len_frames(c0)) / 12.0
		gap60 := f64(c1.timeline_start_frame - (c0.timeline_start_frame + len60)) / 60.0

		// Same CONTENT, to within the frame quantization it has to survive: a 12fps
		// source can only be sampled at 12fps, so 60fps is inherently a coarser view of
		// the same 18.25s. The tolerance is one source frame.
		ok := math.abs(content60 - content12) <= 1.0 / 12.0 + 0.001
		tl_probe_check(
			ok,
			"fps reflow: content must match across rates — %.4fs at 12fps vs %.4fs at 60fps (tolerance one source frame)",
			content12, content60,
		)

		// Same WALL CLOCK, which is what "not slower nor faster" means.
		ok = math.abs(f64(len60)/60.0 - f64(len12)/12.0) <= 1.0 / 60.0 + 0.001
		tl_probe_check(
			ok,
			"fps reflow: wall clock must match — %.4fs at 12fps vs %.4fs at 60fps",
			f64(len12)/12.0, f64(len60)/60.0,
		)

		// And the extent really did re-derive rather than staying pinned: five times
		// the frames at five times the rate.
		tl_probe_check(
			len60 == 1095 && len12 == 219,
			"fps reflow: extent must re-derive from source duration — 219 frames at 12fps, want 1095 at 60fps, got %d",
			len60,
		)

		// The GAP keeps its real-world size. This is what distinguishes preserving gaps
		// from pinning positions: the second clip moved from frame 243 to 1140, so a
		// pin-everything implementation fails here while passing the content checks.
		tl_probe_check(
			math.abs(gap60 - gap12) <= 1.0 / 60.0 + 0.001 && math.abs(gap12 - 2.0) < 0.01,
			"fps reflow: the gap must keep its real-world size — %.4fs, want ~2s",
			gap60,
		)
		tl_probe_check(
			c1.timeline_start_frame == 1095 + 120,
			"fps reflow: the trailing clip must shift by the length delta — start %d, want 1215",
			c1.timeline_start_frame,
		)

		// Round trip: back to 12 must restore the original layout exactly. A reflow
		// that only ever grows is not a reflow.
		set_project_fps(12)
		tl_probe_check(
			timeline.tracks[0].clips[0].source_length_frames == 219 &&
			timeline.tracks[0].clips[1].timeline_start_frame == 243,
			"fps reflow: 60 -> 12 must restore the layout — len %d, second start %d",
			timeline.tracks[0].clips[0].source_length_frames,
			timeline.tracks[0].clips[1].timeline_start_frame,
		)
	}

	// test_fps_reflow_keyframes: keyframes are clip-relative in TIMELINE frames, so
	// an extent that grows fivefold slides every key to a fifth of its position unless
	// they are rescaled with it. The keys survive either way — nothing about a
	// misplaced key looks wrong, which is why this needs its own case.
	test_fps_reflow_keyframes :: proc() {
		tl_fps_scene()
		saved_rate := project.frame_rate
		defer project.frame_rate = saved_rate
		project.frame_rate = 12.0

		c := &timeline.tracks[0].clips[0]
		kf_set_key(c, "transform.x", 109, 5.0)
		kf_set_key(c, "transform.x", 218, 9.0)
		tr := session_trk_view(c.keyframe_tracks, 0)
		before := session_kf_at(tr.keys, 0).frame_off

		set_project_fps(60)
		tr = session_trk_view(c.keyframe_tracks, 0)
		after := session_kf_at(tr.keys, 0).frame_off

		// 109 of 219 is the clip's midpoint; it must still be the midpoint at 1095.
		tl_probe_check(
			before == 109 && after == 545,
			"keyframes must stay on their content across a reflow — offset %d at 219 frames, want %d at 1095",
			after, 545,
		)
		// Strictly ascending: a shrinking reflow folds keys together, and a duplicate
		// offset breaks every interpolating sampler's sorted-ascending assumption.
		set_project_fps(12)
		set_project_fps(60)
		set_project_fps(12)
		tr = session_trk_view(c.keyframe_tracks, 0)
		asc := true
		prev := i32(-1)
		for ki in 0 ..< tr.keys.n {
			off := session_kf_at(tr.keys, ki).frame_off
			if off <= prev {
				asc = false
				break
			}
			prev = off
		}
		tl_probe_check(asc, "keyframes must stay strictly ascending through repeated reflows")
	}


	// test_fps_reflow_assetless: a clip whose asset is gone (a still image, a text
	// generator, a deleted file) has no measured duration — its length comes from the
	// stored extent divided by the rate it was authored at.
	//
	// This is a trap rather than a detail. clip_duration_sec's fallback divides by a
	// rate it is GIVEN, and during a reflow the project rate has already moved to the
	// new one. Dividing a 12-frame one-second still by 60 instead of by 12 turns it
	// into 0.2s, so every asset-less clip on the project silently shrinks by the rate
	// ratio. Nothing about the result looks wrong — the clip still plays, just fast
	// and short.
	test_fps_reflow_assetless :: proc() {
		free_timeline(&timeline)
		clear(&media_bin.assets)
		append(&timeline.tracks, Track{})
		tl := &timeline.tracks[0]
		append(
			&tl.clips,
			Clip{
				clip_id = 3, kind = .Video, is_still = true, asset_id = 9999,
				timeline_start_frame = 0, source_length_frames = 12, src_fps = 12.0,
			},
		)
		saved_rate := project.frame_rate
		defer project.frame_rate = saved_rate

		project.frame_rate = 12.0
		set_project_fps(60)
		c := &timeline.tracks[0].clips[0]
		tl_probe_check(
			c.source_length_frames == 60,
			"a one-second still must stay one second across a reflow — got %d frames at 60fps, want 60",
			c.source_length_frames,
		)
		set_project_fps(12)
		tl_probe_check(
			timeline.tracks[0].clips[0].source_length_frames == 12,
			"and return to 12 frames at 12fps — got %d",
			timeline.tracks[0].clips[0].source_length_frames,
		)
	}


	// test_pin_src_fps_kind_mismatch: the pin must key off the ASSET, not Clip.kind.
	//
	// ~/baby.vyproj stores an AV1 webm as a clip of kind .Audio over an asset of kind
	// .Video. Both pf_pin_src_fps and clip_duration_sec used to filter on the clip's
	// kind, so this clip matched no rung: it kept src_fps=0, resolved to the project
	// rate, and a 12fps source played at 60fps speed — the "5 times faster" report,
	// still live after the conform fix because the pin never ran on it.
	//
	// The fixture mirrors the real file: kind .Audio, asset kind .Video, no probed
	// rate, a frame count and a duration to derive from.
	test_pin_src_fps_kind_mismatch :: proc() {
		tl_pin_scene(0.0, 219, 18250000)
		// Overwrite the scene's clip and asset to the real shape.
		timeline.tracks[0].clips[0].kind = .Audio
		media_bin.assets[0].kind = .Video
		media_bin.assets[0].video_fps = 0 // a project saved before the field existed
		saved_rate := project.frame_rate
		defer project.frame_rate = saved_rate
		project.frame_rate = 60.0

		pf_pin_src_fps()
		c := &timeline.tracks[0].clips[0]
		tl_probe_check(
			c.src_fps > 0 && math.abs(c.src_fps - 12.0) < 0.2,
			"the pin must key off the asset's kind — a .Audio clip over a .Video asset pinned src_fps=%.4f, want ~12",
			c.src_fps,
		)
		// And the observable consequence: one second of a 12fps source is 12 frames,
		// not the 60 an unpinned clip would advance.
		advanced := f64(clip_source_frame(0, 0, 60, false, c.src_fps))
		tl_probe_check(
			math.abs(advanced - 12.0) <= 0.2,
			"a clip whose kind disagrees with its asset must still conform — one second advanced %.3f source frames, want 12",
			advanced,
		)
		// The duration has to come from the same place, or the extent is derived from
		// the wrong quantity and the clip is the wrong length.
		sec := clip_duration_sec(c, 12.0)
		tl_probe_check(
			math.abs(sec - 18.25) < 0.1,
			"duration must come from the asset too — got %.4fs, want ~18.25s",
			sec,
		)
	}


	// test_audio_head_trim is ~/baby.vyproj's "Sr Pelo" clip, which was 5x short at
	// every rate and stayed that way through four rounds of the fps work.
	//
	// Two independent defects, and the second is the one that kept it wrong:
	//
	//  1. Its asset has audio_rate=0 (a project saved before that field existed), so
	//     pf_pin_audio_src_rates fell through to the PROJECT rate — 60 — when the
	//     clip's counts were measured at 11.97 (79 audio frames over 6.6s). A 44-frame
	//     extent read at 60 is 0.733s; at 11.97 it is 3.676s. The audio pin had no
	//     derive rung at all, which is the same gap the video pin had.
	//  2. The clip starts at source frame 35, and the rebase skipped any clip whose
	//     source_start_frame != 0. That is true and irrelevant: the extent is a
	//     LENGTH, and where the clip starts in the source says nothing about how long
	//     it is. Skipping on it left the extent stranded in the authoring timebase.
	//
	// The fixture is the real file's numbers: an audio asset with audio_rate=0,
	// audio_frames=79, dur_us=6.6s, and a clip of 44 frames starting at source frame
	// 35 — a head trim, so not the whole asset, and the asset's 6.6s duration must NOT
	// be used for it.
	test_audio_head_trim :: proc() {
		free_timeline(&timeline)
		clear(&media_bin.assets)
		append(
			&media_bin.assets,
			Media_Asset {
				id = 9201, kind = .Audio, frame_count = 1,
				dur_us = 6600000, audio_rate = 0, audio_frames = 79,
			},
		)
		append(&timeline.tracks, Track{})
		tl := &timeline.tracks[0]
		append(
			&tl.clips,
			Clip {
				clip_id = 9, kind = .Audio, asset_id = 9201,
				timeline_start_frame = 0, source_length_frames = 44, source_start_frame = 35,
			},
		)
		saved_rate := project.frame_rate
		defer project.frame_rate = saved_rate
		project.frame_rate = 60.0

		pf_rebase_extents()

		c := &timeline.tracks[0].clips[0]
		// The duration is 44 frames read at the rate its counts were measured at.
		want := 44.0 / (79.0 * 1e6 / 6600000.0)
		got := f64(c.source_length_frames) / project_fps()
		tl_probe_check(
			math.abs(got - want) < 0.02,
			"a head-trimmed audio clip must keep its real duration — got %.4fs, want %.4fs",
			got, want,
		)
		// NOT the asset's 6.6s: the head trim means this is a fragment, and using the
		// asset's duration would stretch a 3.7s clip to 6.6s.
		tl_probe_check(
			got < 5.0,
			"a trimmed audio clip must not take the asset's full duration — got %.4fs of 6.6s",
			got,
		)
		// And the pin recovered the authoring rate, which is what makes the duration
		// recoverable at all.
		pf_pin_audio_src_rates()
		rate := c.audio_src_rate
		tl_probe_check(
			math.abs(rate - 79.0 * 1e6 / 6600000.0) < 0.05,
			"the audio pin must derive the authoring rate from the asset — got %.4f, want %.4f",
			rate, 79.0 * 1e6 / 6600000.0,
		)

		// And it survives a rate change at both rates.
		targets := ([]f64{12.0, 60.0})
		for target in targets {
			set_project_fps(target)
			d := clip_duration_sec(c, project_fps())
			tl_probe_check(
				math.abs(d - want) < 0.05,
				"the clip must keep %.4fs of audio at %gfps — got %.4fs",
				want, target, d,
			)
		}
	}


	// test_still_extent_survives_load is ~/spooky.vyproj: 21 three-frame stills and then
	// 22 one-frame stills, which loaded as 43 one-frame stills with a two-frame gap
	// between the first 21 -- black frames the author never put there.
	//
	// An image imports as kind=.Video (the probe sees a one-frame video stream) with
	// is_image set, so asset_authoring_rate's `.Image` rung -- "a still has no rate" --
	// was never reached. The .Video rung ran instead and derived a rate from the
	// still's frame_count (one timeline-second, 25) over its dur_us (one frame, 40 ms):
	// 625 fps. pf_rebase_extents then converted each 3-frame extent as 3/625 s at 25 fps
	// = 0.12 frames, rounded to 0 and clamped to 1.
	//
	// The fixture is the real asset's numbers. A still's extent is authored, so load
	// must leave it alone at every length, including the one-frame case that already
	// survived by luck.
	test_still_extent_survives_load :: proc() {
		free_timeline(&timeline)
		clear(&media_bin.assets)
		append(
			&media_bin.assets,
			Media_Asset {
				id = 9401, kind = .Video, is_image = true,
				frame_count = 25, dur_us = 40000, video_fps = 0,
			},
		)
		append(&timeline.tracks, Track{})
		tl := &timeline.tracks[0]
		lengths := []i64{3, 1, 7, 25}
		start := i64(0)
		for len_frames, i in lengths {
			append(
				&tl.clips,
				Clip {
					clip_id = u64(i + 1), kind = .Video, asset_id = 9401, is_still = true,
					timeline_start_frame = start, source_length_frames = len_frames,
				},
			)
			start += len_frames
		}
		saved_rate := project.frame_rate
		defer project.frame_rate = saved_rate
		project.frame_rate = 25.0

		pf_rebase_extents()

		for len_frames, i in lengths {
			got := timeline.tracks[0].clips[i].source_length_frames
			tl_probe_check(
				got == len_frames,
				"a still's authored extent must survive load -- clip %d was %d frames, loaded as %d",
				i, len_frames, got,
			)
		}
		rate, _ := asset_authoring_rate(9401)
		tl_probe_check(rate == 0, "a still has no authoring rate -- derived %.1f fps", rate)
	}


	// test_trim_respects_source_length is the reported bug: dragging the siren head
	// clip's tail out to its source's full length capped at 219 frames.
	//
	// resize_clip_right capped the clip's TIMELINE length with the asset's SOURCE
	// frame count. That was correct only while the two rates matched; at 60fps a
	// 219-frame 12fps source occupies 1096 timeline frames, so the cap landed at a
	// fifth of the real length and the tail could not be dragged out at all.
	//
	// The cap is now converted through the clip's own conform, so the assertion is
	// that dragging to the very end yields the FULL source length in timeline frames —
	// and that stopping one frame short yields one frame less, so the cap is a real
	// bound rather than a wall.
	test_trim_respects_source_length :: proc() {
		free_timeline(&timeline)
		clear(&media_bin.assets)
		append(
			&media_bin.assets,
			Media_Asset {
				id = 9301, kind = .Video, frame_count = 219, dur_us = 18261000, video_fps = 12.0,
			},
		)
		append(&timeline.tracks, Track{})
		tl := &timeline.tracks[0]
		append(
			&tl.clips,
			Clip {
				clip_id = 11, kind = .Video, asset_id = 9301, src_fps = 12.0,
				timeline_start_frame = 0, source_length_frames = 60,
			},
		)
		saved_rate := project.frame_rate
		defer project.frame_rate = saved_rate

		// At 60fps the 219-frame source must be draggable out to 1095 timeline frames.
		project.frame_rate = 60.0
		want := clip_src_len_to_timeline_frames(&tl.clips[0], 219)
		applied := resize_clip_right(tl, 0, i64(1) << 40) // absurd tail: must clamp to the source
		tl_probe_check(
			applied == want && want == 1095,
			"the tail must drag out to the source's full length — applied %d frames, want %d (1095 at 60fps for a 219-frame 12fps source)",
			applied, want,
		)
		// And the bound is real: one frame short of the end is one frame short.
		applied = resize_clip_right(tl, 0, i64(want) - 1)
		tl_probe_check(
			applied == want - 1,
			"one frame short of the source must give one frame less — applied %d, want %d",
			applied, want - 1,
		)
		// Past the end is refused, not wrapped or extended.
		applied = resize_clip_right(tl, 0, i64(want) + 500)
		tl_probe_check(
			applied == want,
			"a tail past the source must clamp, not extend — applied %d, want %d",
			applied, want,
		)

		// The head bound is converted too: a clip whose head sits 35 source frames in
		// may extend left by 35 source frames, expressed in timeline frames.
		free_timeline(&timeline)
		append(&timeline.tracks, Track{})
		tl = &timeline.tracks[0]
		append(
			&tl.clips,
			Clip {
				clip_id = 12, kind = .Video, asset_id = 9301, src_fps = 12.0,
				timeline_start_frame = 600, source_length_frames = 60, source_start_frame = 35,
			},
		)
		head_frames := clip_src_len_to_timeline_frames(&tl.clips[0], 35)
		got_len := resize_clip_left(tl, 0, 0) // drag the head as far left as it will go
		c := &tl.clips[0]
		// The head cannot pass the point where source_start_frame would go negative:
		// 35 source frames back is 175 timeline frames at 60fps.
		limit := 600 - head_frames
		tl_probe_check(
			c.timeline_start_frame == limit,
			"the head must stop where the source runs out — landed at %d, want %d (600 - %d timeline frames for 35 source frames)",
			c.timeline_start_frame, limit, head_frames,
		)
		// And the source offset it adjusted must not go NEGATIVE. Unconverted, the
		// head moved 175 timeline frames and source_start_frame was decremented by
		// all 175, landing at -140 — reading before the source's first frame while the
		// clamp above said the head was still inside the media.
		tl_probe_check(
			c.source_start_frame == 0,
			"dragging the head to the source's start must leave source_start_frame at 0 — got %d",
			c.source_start_frame,
		)
		// A PARTIAL drag, because the clamp above hides the bug at the limit: dragged all
		// the way left, the unconverted delta overshoots to a negative offset that
		// max(0, ...) clamps straight back to 0, so the assertion above passes either
		// way. Mid-drag there is nowhere to hide.
		c.source_start_frame = 35
		c.timeline_start_frame = 600
		c.source_length_frames = 60
		resize_clip_left(tl, 0, 500) // 100 timeline frames left
		tl_probe_check(
			c.source_start_frame == 15,
			"a 100-timeline-frame head drag at 12fps over 60fps must move source_start_frame by 20 — got %d, want 15 (35 - 20)",
			c.source_start_frame,
		)
		tl_probe_check(
			got_len == 660 - limit,
			"the applied length must match the new head — got %d, want %d",
			got_len, 660 - limit,
		)
	}


	// test_head_trim_anchors_tail: every trim must move ONE edge and leave the other
	// where it was.
	//
	// Reported as "moving the left end, and instead of clipping the left end it is
	// clipping the total size" — the clip's RIGHT edge moving too, so the clip shrinks
	// from both sides at once. That is the signature of a tail that is not anchored, and
	// it is invisible in a length assertion alone: the length after a head drag should
	// equal (old length + how far the head moved), and a bug that also drags the tail
	// can produce the right length by moving both edges.
	//
	// So this asserts the EDGES, not the length, and it covers all four handles because
	// they share the failure mode.
	test_head_trim_anchors_tail :: proc() {
		free_timeline(&timeline)
		clear(&media_bin.assets)
		append(
			&media_bin.assets,
			Media_Asset{id = 9501, kind = .Video, frame_count = 600, dur_us = 50000000, video_fps = 30.0},
		)
		append(&timeline.tracks, Track{})
		tl := &timeline.tracks[0]
		append(
			&tl.clips,
			Clip {
				clip_id = 21, kind = .Video, asset_id = 9501, src_fps = 30.0,
				timeline_start_frame = 300, source_length_frames = 120, source_start_frame = 60,
			},
		)
		saved_rate := project.frame_rate
		defer project.frame_rate = saved_rate
		project.frame_rate = 60.0
		c := &tl.clips[0]

		// State is re-read immediately before every operation and never carried across
		// one. Carrying a pre-operation head into a post-operation assertion is wrong in
		// a way that reads like a real failure — this probe's first version compared
		// `head0 + length` and so reported the tail jumping 420 -> 480 when the trim was
		// exact and the tail never moved.
		head := c.timeline_start_frame
		tail := head + c.source_length_frames
		ssrc := c.source_start_frame
		resize_clip_left(tl, 0, head - 60)
		tl_probe_check(
			c.timeline_start_frame == head - 60,
			"head left: head must land where asked — got %d, want %d",
			c.timeline_start_frame, head - 60,
		)
		tl_probe_check(
			c.timeline_start_frame + c.source_length_frames == tail,
			"head left: the TAIL must not move — got %d, want %d",
			c.timeline_start_frame + c.source_length_frames, tail,
		)
		tl_probe_check(
			c.source_length_frames == (tail - head) + 60,
			"head left: length must grow by the head's travel — got %d, want %d",
			c.source_length_frames, (tail - head) + 60,
		)
		// 60 timeline frames at 30fps over a 60fps project is 30 source frames.
		tl_probe_check(
			c.source_start_frame == ssrc - 30,
			"head left: the source offset must move by 30 — got %d, want %d",
			c.source_start_frame, ssrc - 30,
		)

		// Head right: a trim, with the tail still the anchor.
		head = c.timeline_start_frame
		tail = head + c.source_length_frames
		ssrc = c.source_start_frame
		resize_clip_left(tl, 0, head + 40)
		tl_probe_check(
			c.timeline_start_frame + c.source_length_frames == tail,
			"head right: the TAIL must not move — got %d, want %d",
			c.timeline_start_frame + c.source_length_frames, tail,
		)
		tl_probe_check(
			c.source_length_frames == tail - (head + 40),
			"head right: length must shorten by exactly the travel — got %d, want %d",
			c.source_length_frames, tail - (head + 40),
		)
		tl_probe_check(
			c.source_start_frame == ssrc + 20,
			"head right: the source offset must advance by 20 — got %d, want %d",
			c.source_start_frame, ssrc + 20,
		)

		// Tail: the HEAD is the anchor here.
		head = c.timeline_start_frame
		tail = head + c.source_length_frames
		ssrc = c.source_start_frame
		resize_clip_right(tl, 0, tail + 90)
		tl_probe_check(
			c.timeline_start_frame == head,
			"tail: the HEAD must not move — got %d, want %d",
			c.timeline_start_frame, head,
		)
		tl_probe_check(
			c.timeline_start_frame + c.source_length_frames == tail + 90,
			"tail: the tail must land where asked — got %d, want %d",
			c.timeline_start_frame + c.source_length_frames, tail + 90,
		)
		tl_probe_check(
			c.source_start_frame == ssrc,
			"tail: the source offset must not move — got %d, want %d",
			c.source_start_frame, ssrc,
		)
	}

	// select_clips points the selection at `anchor` (track,index) and puts every
	// id in `extra` into the Shift multi-selection, which is exactly the state a
	// shift-click drag leaves behind.
	select_clips :: proc(anchor_track, anchor_index: int, extra: ..u64) {
		selection.track = anchor_track
		selection.index = anchor_index
		clear(&selection.extra_set)
		// The anchor is a member of extra_set as well: that is what select_clip
		// does, and it is why a Shift+click "preserves" the clip a plain click
		// landed on. A probe helper that left it out would be asserting a state
		// the editor never produces.
		if anchor_track >= 0 &&
		   anchor_track < len(timeline.tracks) &&
		   anchor_index >= 0 &&
		   anchor_index < len(timeline.tracks[anchor_track].clips) {
			selection.extra_set[timeline.tracks[anchor_track].clips[anchor_index].clip_id] = true
		}
		for id in extra {
			selection.extra_set[id] = true
		}
	}

	// tl_multi_scene: two lanes, each carrying a linked pair at the front and an
	// unrelated clip behind it.
	//   track 0: 4001(link 42) [0,50)   4003 [100,150)
	//   track 1: 4002(link 42) [0,50)   4004 [100,150)
	tl_multi_scene :: proc() {
		timeline = Timeline {
			tracks = make([dynamic]Track, 0, 2, context.temp_allocator),
		}
		append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 4, context.temp_allocator)})
		append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 4, context.temp_allocator)})
		append(&timeline.tracks[0].clips, mk_tl_clip(4001, 42, 0, 50, 0, .Video))
		append(&timeline.tracks[0].clips, mk_tl_clip(4003, 0, 0, 50, 100, .Video))
		append(&timeline.tracks[1].clips, mk_tl_clip(4002, 42, 0, 50, 0, .Audio))
		append(&timeline.tracks[1].clips, mk_tl_clip(4004, 0, 0, 50, 100, .Audio))
		selection.track = -1
		selection.index = -1
		clear(&selection.extra_set)
		timeline_view.start = 0
	}

	// A selection-wide ripple removes EVERY selected clip's own area from its own
	// track, leaves unselected lanes alone, and lands as ONE undo node. This is
	// the case that used to exist only for a single clip or a single link group.
	test_multi_select_ripple :: proc() {
		tl_multi_scene()
		// 4001 and 4004: one linked member, one unrelated clip. The group
		// expansion brings 4002 along; 4003 is not selected and not linked.
		select_clips(0, 0, 4004)
		before := undo_count()
		ripple_delete_selected()
		tl_probe_check(undo_count() == before + 1, "multi-ripple: want 1 undo node, got %d", undo_count() - before)
		// Track 0: 4001's region gone, 4003 slid left into its place.
		tl_probe_check(len(timeline.tracks[0].clips) == 1, "multi-ripple t0: want 1 clip, got %d", len(timeline.tracks[0].clips))
		if len(timeline.tracks[0].clips) == 1 {
			c := timeline.tracks[0].clips[0]
			tl_probe_check(c.clip_id == 4003 && c.timeline_start_frame == 50, "multi-ripple t0: want 4003 at 50, got %d at %d", c.clip_id, c.timeline_start_frame)
		}
		// Track 1: the linked partner 4002 was ripped too, and 4004 (selected)
		// was ripped, leaving nothing.
		tl_probe_check(len(timeline.tracks[1].clips) == 0, "multi-ripple t1: want 0 clips, got %d", len(timeline.tracks[1].clips))
		tl_probe_check(selection.track == -1 && selection.index == -1 && len(selection.extra_set) == 0, "multi-ripple: selection should be fully cleared")
	}

	// One unlinked clip still rips EVERY track -- the established "delete this
	// area of the timeline" edit. Named here because it is the one place the
	// selection count changes the blast radius, and it is deliberate.
	test_single_clip_ripple_hits_every_track :: proc() {
		tl_multi_scene()
		// Unlink the front pair so the anchor is a lone clip.
		timeline.tracks[0].clips[0].link_id = 0
		timeline.tracks[1].clips[0].link_id = 0
		select_clips(0, 0)
		ripple_delete_selected()
		// [0,50) is removed everywhere: 4003/4004 slide to 50, the two clips that
		// were inside the region are gone.
		tl_probe_check(len(timeline.tracks[0].clips) == 1 && len(timeline.tracks[1].clips) == 1, "every-track: want 1 clip per track, got %d/%d", len(timeline.tracks[0].clips), len(timeline.tracks[1].clips))
	}

	// Two members of ONE link group, both selected, act as the group ONCE. If the
	// expansion emitted 4002 twice, track 1's region would be ripped twice and
	// 4004 would slide from 100 to 0 instead of 50.
	test_multi_select_link_dedup :: proc() {
		tl_multi_scene()
		select_clips(0, 0, 4002)
		ripple_delete_selected()
		tl_probe_check(len(timeline.tracks[1].clips) == 1, "link-dedup t1: want 1 clip, got %d", len(timeline.tracks[1].clips))
		if len(timeline.tracks[1].clips) == 1 {
			c := timeline.tracks[1].clips[0]
			tl_probe_check(c.clip_id == 4004 && c.timeline_start_frame == 50, "link-dedup: 4004 ripped twice, got it at %d", c.timeline_start_frame)
		}
	}

	// Raw delete removes the whole selection (plus partners) and closes no gap,
	// as one undo node.
	test_multi_select_raw_delete :: proc() {
		tl_multi_scene()
		select_clips(0, 0, 4004)
		before := undo_count()
		delete_selected_clip_raw()
		tl_probe_check(undo_count() == before + 1, "multi-raw: want 1 undo node, got %d", undo_count() - before)
		// 4001 + its partner 4002 + selected 4004 gone; 4003 untouched AT 100,
		// because a raw delete does not close the gap.
		tl_probe_check(len(timeline.tracks[0].clips) == 1, "multi-raw t0: want 1 clip, got %d", len(timeline.tracks[0].clips))
		if len(timeline.tracks[0].clips) == 1 {
			c := timeline.tracks[0].clips[0]
			tl_probe_check(c.clip_id == 4003 && c.timeline_start_frame == 100, "multi-raw t0: want 4003 still at 100, got %d", c.timeline_start_frame)
		}
		// Track 1 held 4002 (a partner of the anchor's group) and the selected
		// 4004, so it is left empty.
		tl_probe_check(len(timeline.tracks[1].clips) == 0, "multi-raw t1: want 0 clips, got %d", len(timeline.tracks[1].clips))
	}

	// Split cuts every selected clip that straddles the playhead, and skips the
	// ones it does not -- "split at the playhead" means one thing.
	test_multi_select_split :: proc() {
		tl_multi_scene()
		playhead.frame = 25
		select_clips(0, 0, 4002)
		before := undo_count()
		split_clip_at_playhead()
		tl_probe_check(undo_count() == before + 1, "multi-split: want 1 undo node, got %d", undo_count() - before)
		tl_probe_check(len(timeline.tracks[0].clips) == 3, "multi-split t0: want 3 clips (4001 halves + 4003), got %d", len(timeline.tracks[0].clips))
		tl_probe_check(len(timeline.tracks[1].clips) == 3, "multi-split t1: want 3 clips, got %d", len(timeline.tracks[1].clips))
		// A clip the playhead is not inside is left whole.
		found_whole := false
		for &c in timeline.tracks[0].clips {
			if c.clip_id == 4003 && c.source_length_frames == 50 {
				found_whole = true
			}
		}
		tl_probe_check(found_whole, "multi-split: 4003 does not straddle the playhead and must not be cut")

		// Two clips from DIFFERENT groups must not be linked together by the
		// split: each group's right half gets its own fresh link id.
		tl_multi_scene()
		timeline.tracks[1].clips[0].link_id = 43
		playhead.frame = 25
		select_clips(0, 0, 4002)
		split_clip_at_playhead()
		// The right half is the piece that now begins AT the playhead. Keying on
		// "not the original id" would also match the unrelated 4003, whose link id
		// is 0 and would overwrite what we are reading.
		right0, right1: u64 = 0, 0
		for &c in timeline.tracks[0].clips {
			if c.timeline_start_frame == playhead.frame {
				right0 = c.link_id
			}
		}
		for &c in timeline.tracks[1].clips {
			if c.timeline_start_frame == playhead.frame {
				right1 = c.link_id
			}
		}
		tl_probe_check(right0 != 0 && right1 != 0, "multi-split: both linked clips should keep a link on their right half, got %d/%d", right0, right1)
		tl_probe_check(right0 != right1, "multi-split: splitting two groups linked them together (both right halves got %d)", right0)
	}

	// Shift+clicking a clip selects its WHOLE link group, so the selection can
	// never hold half of a linked pair -- a state no per-clip action can honour.
	test_shift_click_takes_link_group :: proc() {
		// Shift-click an unlinked clip: just that one.
		tl_multi_scene()
		select_clips(0, 0)
		toggle_clip_selection(4003)
		tl_probe_check(len(selection.extra_set) == 2, "shift unlinked: want anchor+4003 = 2, got %d", len(selection.extra_set))
		tl_probe_check(4003 in selection.extra_set, "shift unlinked: 4003 should be selected")
		_, picked := selection.extra_set[4004]
		tl_probe_check(!picked, "shift unlinked: 4004 must NOT be selected (different lane, unlinked)")

		// Shift-click ONE member of the linked pair 42: the partner comes too.
		tl_multi_scene()
		select_clips(0, 0)
		toggle_clip_selection(4002)
		tl_probe_check(4001 in selection.extra_set, "shift linked: 4001 (the partner) should have been selected")
		tl_probe_check(4002 in selection.extra_set, "shift linked: the clicked clip should be selected")
		tl_probe_check(len(selection.extra_set) == 2, "shift linked: want exactly the 2 group members, got %d", len(selection.extra_set))

		// TOGGLE. Clicking a clip that is already selected removes its WHOLE link
		// group -- the user pointed at one member, and the group is the unit every
		// action works in, so half of it is not theirs to leave behind.
		tl_multi_scene()
		select_clips(0, 0)
		toggle_clip_selection(4002)
		toggle_clip_selection(4002)
		tl_probe_check(len(selection.extra_set) == 0, "shift toggle: clicking a selected member should clear the group, got %d", len(selection.extra_set))

		// The direction is decided ONCE for the group, from the CLICKED clip, so a
		// partially-selected group cannot end up half-added by one click.
		tl_multi_scene()
		select_clips(0, 0)
		delete_key(&selection.extra_set, 4002) // 4001 present, partner absent
		toggle_clip_selection(4002)
		tl_probe_check(
			len(selection.extra_set) == 2,
			"shift partial: clicking the absent member should take the group, got %d",
			len(selection.extra_set),
		)
		toggle_clip_selection(4001)
		tl_probe_check(
			len(selection.extra_set) == 0,
			"shift partial: clicking a present member should drop the whole group, got %d",
			len(selection.extra_set),
		)

		// Selection and action agree: a group selected this way is one target set.
		tl_multi_scene()
		select_clips(0, 0)
		toggle_clip_selection(4002)
		targets := selection_targets()
		tl_probe_check(len(targets) == 2, "shift linked: targets want 2, got %d", len(targets))

		// A plain press on empty timeline space deselects everything. The press
		// routes through the click fallback in interaction.odin; what is asserted
		// here is the action it performs, which is the part with state to get wrong.
		clear_clip_selection()
		tl_probe_check(len(selection.extra_set) == 0, "empty-space deselect: want 0 selected, got %d", len(selection.extra_set))
		tl_probe_check(selection.track == -1 && selection.index == -1, "empty-space deselect: anchor should be cleared")
		tl_probe_check(len(selected_clip_ids()) == 0, "empty-space deselect: selected_clip_ids should be empty, got %d", len(selected_clip_ids()))
	}

	// A multi-selection drags as ONE. The press captures the whole selection and
	// every member follows the anchor's delta. This is the case that used to be
	// impossible: the press collapsed the selection to the anchor before the drag
	// began, so dragging one clip of a selection moved exactly one clip.
	test_multi_selection_drag :: proc() {
		timeline = Timeline {
			tracks = make([dynamic]Track, 0, 1, context.temp_allocator),
		}
		append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 4, context.temp_allocator)})
		append(&timeline.tracks[0].clips, mk_tl_clip(5001, 0, 0, 50, 0, .Video))
		append(&timeline.tracks[0].clips, mk_tl_clip(5002, 0, 0, 50, 100, .Video))
		append(&timeline.tracks[0].clips, mk_tl_clip(5003, 0, 0, 50, 200, .Video))
		selection.track = 0
		selection.index = 0
		clear(&selection.extra_set)
		selection.extra_set[5001] = true
		selection.extra_set[5002] = true
		selection.extra_set[5003] = true

		capture_drag_orig(selection_targets())
		tl_probe_check(len(clip_move.group_orig) == 3, "drag set: want 3 clips, got %d", len(clip_move.group_orig))
		tl_probe_check(clip_move.group_orig[0].clip_id == 5001, "drag set: the anchor must lead")

		clip_move.clip = &timeline.tracks[0].clips[0]
		clip_move.clip.timeline_start_frame = 10
		apply_group_drag_to_members(10)
		tl_probe_check(
			timeline.tracks[0].clips[0].timeline_start_frame == 10,
			"drag: anchor should be at 10, got %d",
			timeline.tracks[0].clips[0].timeline_start_frame,
		)
		tl_probe_check(
			timeline.tracks[0].clips[1].timeline_start_frame == 110,
			"drag: member should follow to 110, got %d",
			timeline.tracks[0].clips[1].timeline_start_frame,
		)
		tl_probe_check(
			timeline.tracks[0].clips[2].timeline_start_frame == 210,
			"drag: member should follow to 210, got %d",
			timeline.tracks[0].clips[2].timeline_start_frame,
		)
	}

	// A press that never moved is a click, and a click on a member of a
	// multi-selection narrows the selection to that clip. A drag does not.
	test_click_collapses_selection :: proc() {
		tl_multi_scene()
		select_clips(0, 0, 4002)
		capture_drag_orig(selection_targets())
		tl_probe_check(click_collapses_selection(false), "click: a press that never moved on a multi-selection should collapse")
		tl_probe_check(!click_collapses_selection(true), "drag: a press that moved must NOT collapse")

		// A single clip is already the whole selection; collapsing it is a no-op
		// and must not be reported as one. 4003 is the unlinked clip in
		// tl_multi_scene -- 4001 is linked to 4002, so selecting it alone would
		// expand to a group of two and is not the lone-clip case at all.
		tl_multi_scene()
		select_clips(0, 1)
		capture_drag_orig(selection_targets())
		tl_probe_check(!click_collapses_selection(false), "click: a lone clip is already sole-selected")
	}

	timeline_probe_run :: proc(_: string) {
		tl_scene()
		test_fps_reflow()
		fmt.println("[tl-probe] fps-reflow ok")
		tl_scene()
		test_fps_reflow_assetless()
		fmt.println("[tl-probe] fps-reflow-assetless ok")
		tl_scene()
		test_fps_reflow_keyframes()
		fmt.println("[tl-probe] fps-reflow-keyframes ok")
		tl_scene()
		test_head_trim_anchors_tail()
		fmt.println("[tl-probe] head-trim-anchors-tail ok")
		tl_scene()
		test_trim_respects_source_length()
		fmt.println("[tl-probe] trim-source-length ok")
		tl_scene()
		test_audio_head_trim()
		test_still_extent_survives_load()

		// The TAIL cap on an audio clip, measured in the AUDIO clip's frame space.
		// This is ~/baby.vyproj's opus after the tail cap was converted: the conversion
		// used Clip.src_fps, the VIDEO rate, while the clip's frame numbers are counted
		// against audio_src_rate. Those differ whenever a clip was imported at a
		// different rate than the project — here 11.97 against 60 — so the cap ran 1:1
		// where it had to run 5:1 and the tail clipped at 38 timeline frames instead of
		// the 221 its 44 source frames occupy.
		{
			free_timeline(&timeline)
			clear(&media_bin.assets)
			append(
				&media_bin.assets,
				Media_Asset {
					id = 9401, kind = .Audio, frame_count = 1, dur_us = 6600000,
					audio_rate = 0, audio_frames = 79,
				},
			)
			append(&timeline.tracks, Track{})
			tl := &timeline.tracks[0]
			append(
				&tl.clips,
				Clip {
					clip_id = 13, kind = .Audio, asset_id = 9401,
					timeline_start_frame = 0, source_length_frames = 44, source_start_frame = 35,
				},
			)
			saved_rate := project.frame_rate
			defer project.frame_rate = saved_rate
			project.frame_rate = 60.0
			pf_pin_audio_src_rates()
			c := &tl.clips[0]
			// 44 source frames remain after the head (79 - 35), at the audio rate.
			want := clip_src_len_to_timeline_frames(c, 44)
			applied := resize_clip_right(tl, 0, i64(1) << 40)
			tl_probe_check(
				applied == want && applied == 221,
				"an audio clip's tail cap must convert in its OWN frame space — applied %d timeline frames, want %d (44 source frames at 11.97 over a 60fps project)",
				applied, want,
			)
			// And it must exceed the source's frame count, which is the whole point: a
			// 1:1 conversion would cap at 44 and quietly shorten the clip fivefold.
			tl_probe_check(
				applied > 44,
				"the cap must not be the bare source frame count — got %d, which is the 1:1 conversion",
				applied,
			)
			project.frame_rate = saved_rate
		}
		tl_scene()
		test_pin_src_fps_kind_mismatch()
		fmt.println("[tl-probe] audio-head-trim ok")
		tl_scene()
		test_pin_src_fps_kind_mismatch()
		fmt.println("[tl-probe] pin-kind-mismatch ok")
		tl_scene()
		test_pin_src_fps()
		fmt.println("[tl-probe] pin-src-fps ok")
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

		test_snap_playhead_end_lands_inside_the_clip()
		fmt.println("[tl-probe] playhead-snap-end ok")
		tl_scene()
		test_snap_to_playhead_margin_scales_with_zoom()
		fmt.println("[tl-probe] clip-snap-margin ok")
		tl_scene()

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

		tl_multi_scene()
		test_multi_select_ripple()
		fmt.println("[tl-probe] multi-select-ripple ok")

		tl_multi_scene()
		test_single_clip_ripple_hits_every_track()
		fmt.println("[tl-probe] single-clip-ripple-every-track ok")

		tl_multi_scene()
		test_multi_select_link_dedup()
		fmt.println("[tl-probe] multi-select-link-dedup ok")

		tl_multi_scene()
		test_multi_select_raw_delete()
		fmt.println("[tl-probe] multi-select-raw-delete ok")

		tl_multi_scene()
		test_multi_select_split()
		fmt.println("[tl-probe] multi-select-split ok")

		tl_multi_scene()
		test_shift_click_takes_link_group()
		fmt.println("[tl-probe] shift-click-takes-link-group ok")

		test_multi_selection_drag()
		fmt.println("[tl-probe] multi-selection-drag ok")

		test_click_collapses_selection()
		fmt.println("[tl-probe] click-collapses-selection ok")

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

		tl_ripple_scene()
		test_ripple_set_capture()
		fmt.println("[tl-probe] ripple-capture ok")
		tl_ripple_scene()
		test_ripple_moves_everything_downstream()
		fmt.println("[tl-probe] ripple-downstream ok")
		tl_ripple_scene()
		test_ripple_clamps_flush_on_one_wall()
		fmt.println("[tl-probe] ripple-wall ok")
		tl_ripple_scene()
		test_ripple_stops_at_the_left_edge()
		fmt.println("[tl-probe] ripple-left-edge ok")
		tl_ripple_scene()
		test_ripple_carries_the_shift_selection()
		fmt.println("[tl-probe] ripple-shift-selection ok")
		tl_ripple_scene()
		test_ripple_ignores_a_straddler()
		fmt.println("[tl-probe] ripple-straddler ok")

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

}
