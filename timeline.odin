package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

// ---------------------------------------------------------------------------
// Timeline queries and structural edits: duration/ruler math, frame lookups,
// selection, and track insert/duplicate/naming.
// ---------------------------------------------------------------------------

clip_timeline_end :: proc(clip: Clip) -> i64 {return(
		clip.timeline_start_frame +
		clip.source_length_frames \
	)}

// clip_visible_at reports whether `frame` falls inside a clip occupying
// [start, start+length). HALF-OPEN: the frame at start+length belongs to the
// next clip, not this one, and every caller that wrote the test out longhand got
// this wrong at least once -- main.odin had `>` instead of `>=`, so the
// auto-keyframe gate accepted the playhead one frame past the clip end.
//
// Three i64 rather than a Clip parameter, because the same test applies to
// sources the timeline does not own: Render_Video_Src, Render_Text_Src, subtitle
// clips and the audio track all carry their own start/length pair. A proc over
// Clip would have left those eleven sites inlining the arithmetic, which is
// exactly the duplication this replaces.
clip_visible_at :: proc(frame, start, length: i64) -> bool {
	return frame >= start && frame < start + length
}

// add_text_generator_clip inserts a 1-second Text generator clip on `track`,
// starting at `start_frame` (timeline frames). The duration is one second at the
// current timeline frame rate. If the free gap that contains start_frame can't
// hold a full second, the clip is shortened to fit the neighbor (never shifted).
// Returns the index of the inserted clip.
add_text_generator_clip :: proc(track: ^Track, start_frame: i64) -> int {
	one_sec := i64(math.round(timeline_fps()))
	start := max(start_frame, 0)
	length := one_sec
	if len(track.clips) > 0 {
		gaps := clip_track_gaps(track, -1)
		if gi := gap_for_start(gaps[:], start); gi >= 0 {
			hi := gaps[gi][1]
			if start + length > hi {
				length = clamp(hi - start, 1, length)
			}
		}
	}
	clip := Clip {
		clip_id              = new_clip_id(),
		asset_id             = 0,
		path                 = nil,
		kind                 = .Text,
		generator            = .Text,
		stream_index         = -1,
		source_start_frame   = 0,
		source_length_frames = length,
		timeline_start_frame = start,
		transform_x          = f32(project.width) / 2,
		transform_y          = f32(project.height) / 2,
		scale                = 1,
		crop_l               = 0,
		crop_r               = 0,
		crop_t               = 0,
		crop_b               = 0,
		opacity              = 1,
	}
	append(&track.clips, clip)
	// Keep the track's clips sorted ascending by timeline start.
	idx := len(track.clips) - 1
	for i := idx;
	    i > 0 && track.clips[i].timeline_start_frame < track.clips[i - 1].timeline_start_frame;
	    i -= 1 {
		track.clips[i], track.clips[i - 1] = track.clips[i - 1], track.clips[i]
		idx = i - 1
	}
	return idx
}

// add_subtitle_generator_clip inserts a Subtitle generator clip (kind .Text,
// generator .Subtitles) backed by the parsed srt at cache index src_id on
// `track`, starting at `start_frame`. The natural length is the srt's full
// authored span (never shorter than one second), gap-fitted like the text clip
// (shortened to fit the free gap if it can't hold the whole span; never
// shifted). The caller owns `name` (cloned from the srt's basename downstream).
add_subtitle_generator_clip :: proc(
	track: ^Track,
	start_frame: i64,
	src_id: int,
	name: string,
) -> int {
	one_sec := i64(math.round(timeline_fps()))
	start := max(start_frame, 0)
	src := srt_source(src_id)
	length := max(one_sec, cue_frame(srt_duration_ms(src), f32(timeline_fps())))
	if len(track.clips) > 0 {
		gaps := clip_track_gaps(track, -1)
		if gi := gap_for_start(gaps[:], start); gi >= 0 {
			hi := gaps[gi][1]
			if start + length > hi {
				length = clamp(hi - start, 1, length)
			}
		}
	}
	clip := Clip {
		clip_id              = new_clip_id(),
		asset_id             = 0,
		path                 = nil,
		name                 = session_str_intern(name),
		kind                 = .Text,
		generator            = .Subtitles,
		srt_id               = src_id,
		stream_index         = -1,
		source_start_frame   = 0,
		source_length_frames = length,
		timeline_start_frame = start,
		transform_x          = f32(project.width) / 2,
		transform_y          = f32(project.height) / 2,
		scale                = 1,
		crop_l               = 0,
		crop_r               = 0,
		crop_t               = 0,
		crop_b               = 0,
		opacity              = 1,
	}
	append(&track.clips, clip)
	// Keep the track's clips sorted ascending by timeline start.
	idx := len(track.clips) - 1
	for i := idx;
	    i > 0 && track.clips[i].timeline_start_frame < track.clips[i - 1].timeline_start_frame;
	    i -= 1 {
		track.clips[i], track.clips[i - 1] = track.clips[i - 1], track.clips[i]
		idx = i - 1
	}
	return idx
}

// lane_blocked reports whether [start, start+length) overlaps any clip already on
// the track. Used to refuse an aligned multi-lane import when a partner lane is
// occupied at the anchor frame (a per-lane clamp would desync the group).
lane_blocked :: proc(track: ^Track, start, length: i64) -> bool {
	for c in track.clips {
		if start < clip_timeline_end(c) && start + length > c.timeline_start_frame {
			return true
		}
	}
	return false
}

// snap_margin_frames is how close a target frame must be to a snap point
// (playhead, clip start/end) for the drag/scrub to latch, expressed in frames.
// It is always exactly SNAP_PIXELS on screen: SNAP_PIXELS / zoom scales the
// margin with the pixels-per-frame so the glue band stays a fixed few pixels at
// ANY zoom. (The old max(..,1) floor let the margin balloon to hundreds of
// frames when zoomed out, gluing drags and scrubs onto snap points across the
// whole timeline.)
snap_margin_frames :: proc() -> f32 {
	return f32(SNAP_PIXELS) / timeline_view.zoom
}

// snap_to_playhead latches a clip-drag target onto the playhead when it comes
// within the snap margin. Used by the clip→playhead toggle.
snap_to_playhead :: proc(frame: i64) -> i64 {
	if frame == playhead.frame {
		return frame
	}
	if f32(abs(frame - playhead.frame)) <= snap_margin_frames() {
		return playhead.frame
	}
	return frame
}

// snap_playhead_to_clip_edge latches a scrubbed playhead onto the nearest clip
// start or end frame that falls within the snap margin. Used by the
// playhead→clip toggle.
snap_playhead_to_clip_edge :: proc(frame: i64) -> i64 {
	best := frame
	best_dist := f32(0)
	m := snap_margin_frames()
	for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
		for index := 0; index < len(timeline.tracks[track_idx].clips); index += 1 {
			c := &timeline.tracks[track_idx].clips[index]
			start := c.timeline_start_frame
			end := start + c.source_length_frames
			dist := f32(abs(frame - start))
			if dist <= m && (best == frame || dist < best_dist) {
				best = start
				best_dist = dist
			}
			dist = f32(abs(frame - end))
			if dist <= m && (best == frame || dist < best_dist) {
				best = end
				best_dist = dist
			}
		}
	}
	// A clip end edge is exclusive -- one frame PAST its last content frame --
	// so snapping onto the FINAL clip's end parks the playhead in the void
	// (timeline_duration() is that same exclusive end; frame == dur has no
	// frame to show, and scrubbing already refuses it). Interior end edges
	// (a following clip's start) survive the clamp because dur is the LAST
	// clip's end: only the final edge exceeds it.
	return clamp(best, 0, max(0, timeline_duration() - 1))
}

// clip_track_gaps returns the free (non-covered) bands of `track`, ignoring the
// clip at exclude_idx (-1 = include everything). The trailing band is unbounded
// so clips may still extend the timeline. Allocated on the frame's temp arena
// (edits never outlive the frame), so callers must not retain the result.
clip_track_gaps :: proc(track: ^Track, exclude_idx: int) -> [dynamic][2]i64 {
	gaps := make([dynamic][2]i64, 0, len(track.clips) + 1, context.temp_allocator)
	if len(track.clips) == 0 {
		append(&gaps, [2]i64{0, max(0, i64(1 << 40))})
		return gaps
	}
	covered := make([dynamic][2]i64, 0, len(track.clips), context.temp_allocator)
	for i in 0 ..< len(track.clips) {
		if i == exclude_idx {
			continue
		}
		c := track.clips[i]
		append(&covered, [2]i64{c.timeline_start_frame, clip_timeline_end(c)})
	}
	for i in 1 ..< len(covered) {
		for j := i; j > 0 && covered[j][0] < covered[j - 1][0]; j -= 1 {
			covered[j], covered[j - 1] = covered[j - 1], covered[j]
		}
	}
	band_end: i64 = 0
	for c in covered {
		if c[0] > band_end {
			append(&gaps, [2]i64{band_end, c[0]})
		}
		if c[1] > band_end {
			band_end = c[1]
		}
	}
	append(&gaps, [2]i64{band_end, band_end + max(1, i64(1 << 40))})
	return gaps
}

// gap_for_start returns the index of the free band that contains `at`, or the
// nearest one if `at` itself is covered by a clip.
gap_for_start :: proc(gaps: [][2]i64, at: i64) -> int {
	best := 0
	best_dist := i64(1 << 40)
	for gi in 0 ..< len(gaps) {
		lo, hi := gaps[gi][0], gaps[gi][1]
		if at >= lo && at <= hi {
			return gi
		}
		d := at - lo
		if d < 0 {
			d = -d
		}
		if d < best_dist {
			best_dist = d
			best = gi
		}
	}
	return best
}

// clip_place_in_track returns a timeline_start_frame for a clip of clip_len
// frames in `track` that is as close as possible to `desired` yet overlaps no
// other clip. The result is the nearest valid non-overlapping position.
// exclude_idx is the clip being dragged itself (-1 = none), which may already
// sit in the track.
clip_place_in_track :: proc(track: ^Track, exclude_idx: int, clip_len: i64, desired: i64) -> i64 {
	if clip_len <= 0 {
		return desired
	}
	if len(track.clips) == 0 {
		return max(desired, 0)
	}
	gaps := clip_track_gaps(track, exclude_idx)
	best_gap := -1
	best_dist := i64(1 << 40)
	for gi in 0 ..< len(gaps) {
		lo, hi := gaps[gi][0], gaps[gi][1]
		if hi - lo < clip_len {
			continue
		}
		d := desired - lo
		if d < 0 {
			d = -d
		}
		if d < best_dist {
			best_dist = d
			best_gap = gi
		}
	}
	if best_gap < 0 {
		return max(desired, 0)
	}
	lo := gaps[best_gap][0]
	hi := gaps[best_gap][1] - clip_len
	return clamp(desired, lo, hi)
}

// clip_slide_in_track clamps `desired` so the clip stays inside the free gap
// that currently contains `anchor` (its live position): same-track horizontal
// drags slide freely within their band but never cross/collide with a neighbor,
// and never jump to a far gap when the pointer briefly crosses a clip.
clip_slide_in_track :: proc(
	track: ^Track,
	exclude_idx: int,
	clip_len: i64,
	desired, anchor: i64,
) -> i64 {
	if clip_len <= 0 {
		return desired
	}
	if len(track.clips) == 0 {
		return max(desired, 0)
	}
	gaps := clip_track_gaps(track, exclude_idx)
	gi := gap_for_start(gaps[:], anchor)
	if gi < 0 || gi >= len(gaps) {
		return max(desired, 0)
	}
	lo := gaps[gi][0]
	hi := gaps[gi][1] - clip_len
	if hi < lo {
		// The band can't hold the clip at all (shouldn't happen: the clip
		// already lives inside it) — fall back to the plain placement.
		return clip_place_in_track(track, exclude_idx, clip_len, desired)
	}
	return clamp(desired, lo, hi)
}

// asset_source_frames returns the total source frame count available to a clip
// of `kind` on its asset, or -1 when unknown (no asset / generator clip). An
// audio clip's media is bounded by the asset's audio_frames, NOT frame_count:
// an audio-only file probes no video stream, so frame_count falls back to 1 and
// capping on it would lock the clip to a single frame. Used to cap lengthening
// so a clip never references past the end of its source media.
asset_source_frames :: proc(asset_id: u64, kind: Media_Kind) -> i64 {
	for &a in media_bin.assets {
		if a.id == asset_id {
			return kind == .Audio ? a.audio_frames : a.frame_count
		}
	}
	return -1
}

// clip_next_start returns the timeline start of the nearest clip after `idx` on
// `track` (or a large sentinel if none), so a right-edge resize never overlaps.
clip_next_start :: proc(track: ^Track, idx: int) -> i64 {
	for i := idx + 1; i < len(track.clips); i += 1 {
		return track.clips[i].timeline_start_frame
	}
	return i64(1) << 50
}

// clip_prev_end returns the timeline end of the nearest clip before `idx` on
// `track` (or a large negative sentinel if none), so a left-edge resize never
// overlaps.
clip_prev_end :: proc(track: ^Track, idx: int) -> i64 {
	for i := idx - 1; i >= 0; i -= 1 {
		return clip_timeline_end(track.clips[i])
	}
	return -(i64(1) << 50)
}

// resize_clip_right sets the clip's tail (timeline end) to new_tail, trimming
// or extending the tail. Length is clamped to >= 1 frame, to the source frames
// available after the head (so a file-backed clip never overruns its media), and
// so the tail never passes the next clip's start. Generator clips (no source
// cap) grow freely until a neighbor. A still image has no time-varying source,
// so it grows freely too: its synthetic one-second frame count is a default
// length, not a media bound. Returns the applied length.
resize_clip_right :: proc(track: ^Track, idx: int, new_tail: i64) -> i64 {
	c := &track.clips[idx]
	start := c.timeline_start_frame
	max_len := i64(1) << 50
	if !c.is_still {
		if src_total := asset_source_frames(c.asset_id, c.kind); src_total > 0 {
			max_len = max(1, src_total - c.source_start_frame)
		}
	}
	next := clip_next_start(track, idx)
	lo := start + 1
	hi := min(start + max_len, next)
	if hi < lo {
		hi = lo
	}
	tail := clamp(new_tail, lo, hi)
	c.source_length_frames = tail - start
	return c.source_length_frames
}

// resize_clip_left moves the clip's head (timeline start) to new_head while
// keeping the tail anchored. The head shifts source_start_frame with it, and is
// clamped so the clip never overlaps the previous neighbor, never drops below 1
// frame, and never extends before the source (source_start_frame >= 0). A still
// image has no time-varying source, so its head extends left freely (bounded
// only by the previous neighbor and frame 0) and keeps source_start_frame at 0.
// Returns the applied length.
resize_clip_left :: proc(track: ^Track, idx: int, new_head: i64) -> i64 {
	c := &track.clips[idx]
	start := c.timeline_start_frame
	ssrc := c.source_start_frame
	end := start + c.source_length_frames
	// The head may extend left only as far as source frames precede the head.
	min_start := start - ssrc
	if c.is_still {
		min_start = 0
	}
	prev := clip_prev_end(track, idx)
	lo := max(min_start, prev)
	hi := end - 1
	if lo > hi {
		lo = hi
	}
	head := clamp(new_head, lo, hi)
	delta := head - start
	if !c.is_still {
		c.source_start_frame += delta
	}
	c.timeline_start_frame = head
	c.source_length_frames = end - head
	return c.source_length_frames
}

// resize_clip_seam rolls a shared boundary between adjacent clips: left tail
// and right head move together, while left head and right tail remain fixed.
// Clamp to one frame per clip, the left source's last frame, and the right
// source's first frame. Stills have no varying-source bound.
resize_clip_seam :: proc(track: ^Track, left_idx, right_idx: int, new_seam: i64) -> i64 {
	assert(left_idx >= 0 && right_idx == left_idx+1 && right_idx < len(track.clips),
		"resize_clip_seam: clips must be adjacent on one track")
	left := &track.clips[left_idx]
	right := &track.clips[right_idx]
	old_seam := clip_timeline_end(left^)
	assert(old_seam == right.timeline_start_frame, "resize_clip_seam: clips do not touch")
	left_start := left.timeline_start_frame
	right_end := clip_timeline_end(right^)
	lo := left_start + 1
	hi := right_end - 1
	if right.is_still {
		lo = max(lo, 0)
	} else {
		lo = max(lo, old_seam-right.source_start_frame)
	}
	if !left.is_still {
		if source_total := asset_source_frames(left.asset_id, left.kind); source_total > 0 {
			max_left_len := max(1, source_total-left.source_start_frame)
			hi = min(hi, left_start+max_left_len)
		}
	}
	assert(lo <= hi, "resize_clip_seam: no valid frame boundary remains")
	seam := clamp(new_seam, lo, hi)
	delta := seam - old_seam
	left.source_length_frames = seam - left_start
	right.timeline_start_frame = seam
	if !right.is_still {
		right.source_start_frame += delta
	}
	right.source_length_frames = right_end - seam
	return seam
}

timeline_duration :: proc() -> i64 {
	dur := i64(0)
	for track in timeline.tracks {
		for cl in track.clips {
			e := clip_timeline_end(cl)
			if e > dur {
				dur = e
			}
		}
	}
	return dur
}

// split_clip_at_playhead splits the first clip covering the playhead frame into
// two adjacent clips at that frame (the frame stays with the left half). When
// the clip belongs to a link group, EVERY member whose span covers the playhead
// is split at the same frame: the left halves keep the original group and the
// right halves mint one fresh link group (they still time-align with each other,
// just no longer glued to the left halves). Both halves keep their in-range
// markers; each right half is inserted right after its left so the two touch.
split_clip_at_playhead :: proc() {
	frame := playhead.frame
	tr, clip, ok := selected_clip()
	if !ok ||
	   clip == nil ||
	   frame < clip.timeline_start_frame ||
	   frame >= clip_timeline_end(clip^) {
		// The selection doesn't straddle the playhead (or nothing is selected):
		// "split at playhead" must cut the clip UNDER the playhead, not whatever
		// happens to be selected. Resolve by coverage and move the selection to
		// the cut clip so the UI reads what was just cut.
		tr, clip, ok = clip_at_frame(frame)
		if !ok || clip == nil {
			return
		}
		selection.track = track_index_of(tr)
		selection.index = clip_index_on_track(tr, clip)
	}
	local := frame - clip.timeline_start_frame
	if local <= 0 || local >= clip.source_length_frames {
		return
	}
	undo_begin()
	link := clip.link_id
	right_link := u64(0)
	if link != 0 {
		right_link = new_clip_id()
	}
	SplitTarget :: struct {
		track, index: int,
	}
	targets := make([dynamic]SplitTarget, 0, 4, context.temp_allocator)
	if link != 0 {
		for t := 0; t < len(timeline.tracks); t += 1 {
			for i := 0; i < len(timeline.tracks[t].clips); i += 1 {
				c := &timeline.tracks[t].clips[i]
				if c.link_id == link &&
				   clip_visible_at(frame, c.timeline_start_frame, c.source_length_frames) {
					append(&targets, SplitTarget{t, i})
				}
			}
		}
	} else {
		append(&targets, SplitTarget{selection.track, selection.index})
	}
	if len(targets) == 0 {
		return
	}
	// Descending index order per track so injecting a right half never
	// invalidates a still-pending target's index on the same track.
	for t in 0 ..< len(targets) {
		for i := t + 1; i < len(targets); i += 1 {
			if targets[i].track > targets[t].track ||
			   (targets[i].track == targets[t].track && targets[i].index > targets[t].index) {
				targets[t], targets[i] = targets[i], targets[t]
			}
		}
	}
	for target in targets {
		if target.track < 0 || target.track >= len(timeline.tracks) {
			continue
		}
		tt := &timeline.tracks[target.track]
		if target.index < 0 || target.index >= len(tt.clips) {
			continue
		}
		c := &tt.clips[target.index]
		left_len := frame - c.timeline_start_frame
		right_len := c.source_length_frames - left_len
		if left_len <= 0 || right_len <= 0 {
			continue
		}
		// Build both halves from source ranges before releasing their exclusive
		// spans. Undo snapshots may also hold these ranges, so release honors COW.
		source_markers := c.markers
		source_tracks := c.keyframe_tracks
		right := c^
		// The new half is a distinct clip instance: re-mint its identity instead
		// of inheriting the left half's id (two clips sharing one clip_id breaks
		// every clip_id-keyed path -- preview slot identity, find_preview_slot,
		// the prewarm decoder handoff).
		right.clip_id = new_clip_id()
		right.link_id = right_link
		// A still image shows the same frame everywhere; its source offset must
		// stay 0 or the right half would ask the decoder for a frame the image
		// doesn't have. Only time-varying sources advance the right half's start.
		if !c.is_still {
			right.source_start_frame += left_len
		}
		right.source_length_frames = right_len
		right.timeline_start_frame = frame
		c.markers = filter_markers_in_range(
			source_markers,
			c.source_start_frame,
			left_len,
		)
		c.source_length_frames = left_len
		right.markers = filter_markers_in_range(
			source_markers,
			right.source_start_frame,
			right_len,
		)
		// Split remap (slice-1 rule): left keeps keys < left_len, right gets
		// keys >= left_len re-relativized by -left_len; both read source before
		// either candidate replaces it.
		kf_bump_structure()
		c.keyframe_tracks = kf_rebuild_tracks(source_tracks, 0, i32(left_len))
		right.keyframe_tracks = kf_rebuild_tracks(source_tracks, i32(left_len), KF_MAX_OFFSET)
		session_marker_release(source_markers)
		kf_free_tracks(source_tracks)
		inject_at_elem(&tt.clips, target.index + 1, right)
	}
	if vyper_trace {
		fmt.printf("[tl] split group link=%d (%d clips) @ %d\n", link, len(targets), frame)
	}
	undo_push(.Split, "Split clip(s)")
	audio_note_edit()
}

// unlink_selected_clips severs the selected clip's link group: every clip that
// shared its link_id becomes independent (link_id = 0), so later cuts, moves and
// deletes touch only the clip you grabbed. The selection stays on that clip.
unlink_selected_clips :: proc() {
	_, clip, ok := selected_clip()
	if !ok || clip == nil || clip.link_id == 0 {
		return
	}
	link := clip.link_id
	count := 0
	for t := 0; t < len(timeline.tracks); t += 1 {
		for i := 0; i < len(timeline.tracks[t].clips); i += 1 {
			if timeline.tracks[t].clips[i].link_id == link {
				timeline.tracks[t].clips[i].link_id = 0
				count += 1
			}
		}
	}
	if count == 0 {
		return
	}
	// Any group drag math captured earlier is now invalid: members are free.
	clear(&clip_move.group_orig)
	audio_note_edit()
	if vyper_trace {
		fmt.printf("[tl] unlinked %d clips (was link=%d)\n", count, link)
	}
}

// toggle_links_for_selection links or unlinks the current selection: the anchor
// clip plus every Shift+clicked clip in selection.extra_set. A lone selection unlinks
// that clip's whole link group (video + audio become independent). With several
// clips the action toggles: if they already share one link_id every selected
// member is unlinked, otherwise they all join a fresh link group so later
// cuts/moves/deletes treat them as one unit.
toggle_links_for_selection :: proc() {
	_, anchor, ok := selected_clip()
	ids := make([dynamic]u64, 0, len(selection.extra_set) + 1, context.temp_allocator)
	if ok && anchor != nil {
		append(&ids, anchor.clip_id)
	}
	for id in selection.extra_set {
		dup := false
		for o in ids {
			if o == id {
				dup = true
				break
			}
		}
		if !dup {
			append(&ids, id)
		}
	}
	if len(ids) == 0 {
		return
	}
	resolved := make([dynamic]^Clip, 0, len(ids), context.temp_allocator)
	for t := 0; t < len(timeline.tracks); t += 1 {
		for i := 0; i < len(timeline.tracks[t].clips); i += 1 {
			c := &timeline.tracks[t].clips[i]
			for id in ids {
				if c.clip_id == id {
					append(&resolved, c)
				}
			}
		}
	}
	if len(resolved) == 0 {
		return
	}
	if len(resolved) == 1 {
		// Sole selection: sever its own link group, mirroring the original U.
		c := resolved[0]
		if c.link_id == 0 {
			return
		}
		link := c.link_id
		count := 0
		for t := 0; t < len(timeline.tracks); t += 1 {
			for i := 0; i < len(timeline.tracks[t].clips); i += 1 {
				if timeline.tracks[t].clips[i].link_id == link {
					timeline.tracks[t].clips[i].link_id = 0
					count += 1
				}
			}
		}
		if count == 0 {
			return
		}
		audio_note_edit()
		if vyper_trace {
			fmt.printf("[tl] unlinked %d clips (was link=%d)\n", count, link)
		}
		return
	}
	common := resolved[0].link_id
	same_group := common != 0
	for c in resolved {
		if c.link_id != common {
			same_group = false
			break
		}
	}
	clear(&clip_move.group_orig)
	if same_group {
		for c in resolved {
			c.link_id = 0
		}
		audio_note_edit()
		if vyper_trace {
			fmt.printf("[tl] unlinked %d selected clips\n", len(resolved))
		}
		return
	}
	new_link := new_clip_id()
	for c in resolved {
		c.link_id = new_link
	}
	audio_note_edit()
	if vyper_trace {
		fmt.printf("[tl] linked %d selected clips (link=%d)\n", len(resolved), new_link)
	}
}

// filter_markers_in_range builds a session range with markers in the half-open
// source interval. Rows are POD and labels remain session string handles.
filter_markers_in_range :: proc(
	markers: Clip_Markers_Range,
	start, length: i64,
) -> Clip_Markers_Range {
	out := Clip_Markers_Range{}
	for i in 0..<markers.n {
		m := session_marker_at(markers, i)
		if m.source_frame >= start && m.source_frame < start + length {
			session_marker_push(&out, m)
		}
	}
	return out
}

// clip_marker_mut resolves marker-range COW before a marker field edit.
clip_marker_mut :: proc(c: ^Clip, i: int) -> ^Clip_Marker {
	return session_marker_at_mut(&c.markers, i)
}

// clip_ranges_release returns this Clip's exclusive session ranges to their
// arenas. Shared ranges remain reserved for the other Clip/undo snapshot.
clip_ranges_release :: proc(c: ^Clip) {
	session_marker_release(c.markers)
	kf_free_tracks(c.keyframe_tracks)
	c.markers = Clip_Markers_Range{}
	c.keyframe_tracks = Kf_Track_Range{}
}

// delete_selected_clip_raw removes the selected clip (and, when it belongs to a
// link group, EVERY member of that group) from the timeline. No ripple, no
// region removal, no other clips/tracks affected: the timeline simply stops
// showing the clip(s) (a gap stays where they were). The group scope keeps a cut
// from leaving its video behind with no audio (or vice versa).
delete_selected_clip_raw :: proc() {
	if selection.track < 0 || selection.track >= len(timeline.tracks) {
		return
	}
	track := &timeline.tracks[selection.track]
	if selection.index < 0 || selection.index >= len(track.clips) {
		return
	}
	undo_begin()
	link := track.clips[selection.index].link_id
	Target :: struct {
		track, index: int,
	}
	targets := make([dynamic]Target, 0, 4, context.temp_allocator)
	if link != 0 {
		for t := 0; t < len(timeline.tracks); t += 1 {
			for i := 0; i < len(timeline.tracks[t].clips); i += 1 {
				if timeline.tracks[t].clips[i].link_id == link {
					append(&targets, Target{t, i})
				}
			}
		}
	} else {
		append(&targets, Target{selection.track, selection.index})
	}
	// Descending (track, index) so a removal on one track never invalidates a
	// still-pending target's index on the same track.
	for t in 0 ..< len(targets) {
		for i := t + 1; i < len(targets); i += 1 {
			if targets[i].track > targets[t].track ||
			   (targets[i].track == targets[t].track && targets[i].index > targets[t].index) {
				targets[t], targets[i] = targets[i], targets[t]
			}
		}
	}
	removed_any := false
	for target in targets {
		if target.track < 0 || target.track >= len(timeline.tracks) {
			continue
		}
		tt := &timeline.tracks[target.track]
		if target.index < 0 || target.index >= len(tt.clips) {
			continue
		}
		removed := tt.clips[target.index]
		ordered_remove(&tt.clips, target.index)
		clip_ranges_release(&removed)
		if vyper_trace {
			fmt.printf(
				"[tl] deleted clip raw src=%s start=%d len=%d\n",
				removed.path,
				removed.timeline_start_frame,
				removed.source_length_frames,
			)
		}
		removed_any = true
	}
	if !removed_any {
		return
	}
	if vyper_trace {
		fmt.printf("[tl] deleted clip group link=%d (%d clips)\n", link, len(targets))
	}
	selection.track = -1
	selection.index = -1
	// CRITICAL: invalidation MUST follow every delete. The timeline no longer
	// references `removed`, but the per-clip preview slots still hold this
	// clip's decoded frames, open decoder, and GPU texture. Without
	// invalidate_preview_slots the deleted clip keeps painting at the playhead
	// (classic "deleted clip still renders" bug). Do not remove this regardless
	// of how the delete is wired — any new delete path must do the same.
	active_interaction = .None
	clip_move.clip = nil
	clip_move.source_track = -1
	clip_move.source_index = -1
	clip_move.hover_track = -1
	invalidate_preview_slots()
	undo_push(.Delete, "Delete clip")
	audio_note_edit()
}

// ripple_delete_track_region removes the timeline region [start, start+length)
// from a single track and closes that track's gap: clips fully after the region
// shift left by `length`, clips straddling the edges get trimmed/split around
// it, and clips entirely inside it are dropped. Shared by the all-tracks ripple
// (ripple_delete_region) and the whole-link-group ripple so a linked cut can
// rip each member's OWN span on its OWN lane.
ripple_delete_track_region :: proc(ti: int, start, length: i64) {
	if length <= 0 {
		return
	}
	end := start + length
	track := &timeline.tracks[ti]
	// Rebuilt clip array BECOMES the track's clips (delete + reassign below):
	// persistent, so context.allocator, not the frame temp arena.
	new_clips := make([dynamic]Clip, 0, len(track.clips))
	for i in 0 ..< len(track.clips) {
		c := track.clips[i]
		cs := c.timeline_start_frame
		ce := clip_timeline_end(c)
		switch {
		case ce <= start:
			// Entirely before the region: transfer the POD record unchanged.
			append(&new_clips, c)
		case cs >= end:
			// Entirely after the region: slide left to close the gap.
			c.timeline_start_frame -= length
			append(&new_clips, c)
		case cs < start && ce > end:
			// Straddles the whole region: split into left + right pieces.
			source_markers := c.markers
			source_tracks := c.keyframe_tracks
			right := c
			right.clip_id = new_clip_id()

			left := c
			left.source_length_frames = start - cs
			left.markers = filter_markers_in_range(
				source_markers,
				left.source_start_frame,
				left.source_length_frames,
			)

			if !right.is_still {
				right.source_start_frame += end - cs
			}
			right.source_length_frames = ce - end
			right.timeline_start_frame = start
			right.markers = filter_markers_in_range(
				source_markers,
				right.source_start_frame,
				right.source_length_frames,
			)
			// Left keeps keys < cut; right keeps keys >= cut and re-relativizes.
			cut := i32(start - cs)
			kf_bump_structure()
			left.keyframe_tracks = kf_rebuild_tracks(source_tracks, 0, cut)
			right.keyframe_tracks = kf_rebuild_tracks(source_tracks, cut, KF_MAX_OFFSET)
			session_marker_release(source_markers)
			kf_free_tracks(source_tracks)
			append(&new_clips, left)
			append(&new_clips, right)
		case cs < start:
			// Overlaps the left edge only: trim its tail.
			old_markers := c.markers
			c.source_length_frames = start - cs
			c.markers = filter_markers_in_range(
				old_markers,
				c.source_start_frame,
				c.source_length_frames,
			)
			kf_trim_tail(&c, i32(start - cs))
			append(&new_clips, c)
			session_marker_release(old_markers)
		case ce > end:
			// Overlaps the right edge only: trim its head, shifted to start.
			// The trimmed head is [cs, end), so the source advances by end - cs
			// -- the same value the straddle-split's right piece uses. Using
			// cs - start here advances by the wrong amount whenever the clip
			// head is not exactly at the region midpoint, leaving the clip
			// reading the wrong source frames under the playhead (A/V desync).
			old_markers := c.markers
			if !c.is_still {
				c.source_start_frame += end - cs
			}
			c.source_length_frames = ce - end
			c.timeline_start_frame = start
			c.markers = filter_markers_in_range(
				old_markers,
				c.source_start_frame,
				c.source_length_frames,
			)
			// Keyframes are clip-relative: head trimmed off means keys <
			// (start-cs) go with the removed head, survivors re-relativize by
			// - (start-cs).
			kf_trim_head(&c, i32(start - cs))
			append(&new_clips, c)
			session_marker_release(old_markers)
		case cs >= start && ce <= end:
			// Otherwise the clip is entirely inside the region: dropped.
			clip_ranges_release(&c)
		}
	}
	delete(track.clips)
	track.clips = new_clips
}

// ripple_playhead_after_region moves the playhead to follow a ripple that
// removed [start, end) and slid everything after it left by `length`. A
// playhead at/after the region end tracks the same content and moves left by
// the removed span; one inside the region clamps to the cut; one before the
// region is untouched. Callers must move the playhead BEFORE audio_note_edit so
// the audio producer re-seeks to the new frame.
//
// The timeline view pans by the same frame delta, so the playhead keeps its
// on-screen position and the content at/after it stays put while the removed
// span collapses behind it. Without this the view holds still and the playhead
// (with every downstream clip) flies off to the left.
ripple_playhead_after_region :: proc(start, end, length: i64) {
	before := playhead.frame
	if playhead.frame >= end {
		playhead.frame -= length
	} else if playhead.frame > start {
		playhead.frame = start
	}
	if delta := playhead.frame - before; delta != 0 {
		timeline_view.start = clamp(
			timeline_view.start + f32(delta),
			0,
			f32(timeline_duration()),
		)
	}
}

// ripple_delete_region removes the timeline region [start, start+length) from
// EVERY track at once (the "delete the clip area for all tracks" edit) and then
// closes the gap: clips fully after the region shift left by `length`, clips
// straddling the region edges get trimmed/split around it, and clips entirely
// inside it are dropped.
ripple_delete_region :: proc(start, length: i64) {
	if length <= 0 {
		return
	}
	undo_begin()
	for ti in 0 ..< len(timeline.tracks) {
		ripple_delete_track_region(ti, start, length)
	}
	ripple_playhead_after_region(start, start + length, length)
	// The edit may have removed/replaced the dragged clip and the decoded state
	// cached for it: cancel any in-flight drag and drop the preview slots so the
	// next update re-derives them purely from the edited timeline.
	active_interaction = .None
	clip_move.clip = nil
	clip_move.source_track = -1
	clip_move.source_index = -1
	clip_move.hover_track = -1
	invalidate_preview_slots()
	if vyper_trace {
		fmt.printf("[tl] ripple delete region [%d, %d)\n", start, start + length)
	}
	selection.track = -1
	selection.index = -1
	undo_push(.Delete, "Delete region")
	audio_note_edit()
}

// ripple_delete_linked_group ripple-deletes a whole link group: EVERY member's
// own region is removed on its own track and that track's gap is closed by the
// member's span there, so a linked ripple cut leaves no partner clip behind
// (the all-tracks region edit only ever rips the SELECTED member's span, which
// is usually elsewhere on other members' lanes). Members are processed per
// track from rightmost to leftmost: an earlier ripple shifts only clips AFTER
// its region, so the recorded spans of members still pending stay valid.
ripple_delete_linked_group :: proc(link: u64) {
	if link == 0 {
		return
	}
	MemberSpan :: struct {
		track:         int,
		start, length: i64,
	}
	spans := make([dynamic]MemberSpan, 0, 4, context.temp_allocator)
	for ti in 0 ..< len(timeline.tracks) {
		for &c in timeline.tracks[ti].clips {
			if c.link_id == link {
				append(&spans, MemberSpan{ti, c.timeline_start_frame, c.source_length_frames})
			}
		}
	}
	if len(spans) == 0 {
		return
	}
	undo_begin()
	// Capture the anchor span (the clip the user deleted) before the ripple
	// invalidates indices and before the selection is cleared below. The
	// playhead follows that span's shift, the same way the single-region ripple
	// moves it -- the other members ripple their own lanes, not the playhead's
	// frame of reference.
	anchor_start, anchor_len: i64
	have_anchor := false
	if selection.track >= 0 &&
	   selection.track < len(timeline.tracks) &&
	   selection.index >= 0 &&
	   selection.index < len(timeline.tracks[selection.track].clips) {
		anchor := timeline.tracks[selection.track].clips[selection.index]
		if anchor.link_id == link {
			anchor_start = anchor.timeline_start_frame
			anchor_len = anchor.source_length_frames
			have_anchor = true
		}
	}
	// Sort by (track asc, start DESC).
	for a in 0 ..< len(spans) {
		for b := a + 1; b < len(spans); b += 1 {
			later :=
				spans[b].track < spans[a].track ||
				(spans[b].track == spans[a].track && spans[b].start > spans[a].start)
			if later {
				spans[a], spans[b] = spans[b], spans[a]
			}
		}
	}
	for s in spans {
		ripple_delete_track_region(s.track, s.start, s.length)
	}
	if have_anchor {
		ripple_playhead_after_region(
			anchor_start,
			anchor_start + anchor_len,
			anchor_len,
		)
	}
	active_interaction = .None
	clip_move.clip = nil
	clip_move.source_track = -1
	clip_move.source_index = -1
	clip_move.hover_track = -1
	invalidate_preview_slots()
	if vyper_trace {
		fmt.printf("[tl] ripple delete linked group link=%d (%d members)\n", link, len(spans))
	}
	selection.track = -1
	selection.index = -1
	undo_push(.Delete, "Delete group")
	audio_note_edit()
}

// ruler_steps returns minor/major tick strides (in frames) for a timeline of the
// given duration, roughly 10 minors per major and <= 100 majors total.
ruler_steps :: proc(duration: i64) -> (minor, major: i64) {
	minor = 1
	for duration / minor > 100 * 10 {
		minor *= 10
	}
	major = minor * 10
	return
}

selected_clip :: proc() -> (^Track, ^Clip, bool) {
	if selection.track >= 0 && selection.track < len(timeline.tracks) {
		tr := &timeline.tracks[selection.track]
		if selection.index >= 0 && selection.index < len(tr.clips) {
			return tr, &tr.clips[selection.index], true
		}
	}
	return nil, nil, false
}

// clip_at_frame returns the first clip across all tracks whose timeline span
// covers `frame` (any kind). Track order first, then clip order — the clip the
// pointer/playhead rests on for a coverage-driven edit.
clip_at_frame :: proc(frame: i64) -> (^Track, ^Clip, bool) {
	for ti in 0 ..< len(timeline.tracks) {
		for ci in 0 ..< len(timeline.tracks[ti].clips) {
			c := &timeline.tracks[ti].clips[ci]
			if clip_visible_at(frame, c.timeline_start_frame, c.source_length_frames) {
				return &timeline.tracks[ti], c, true
			}
		}
	}
	return nil, nil, false
}

// track_index_of / clip_index_on_track locate a resolved pointer inside the
// timeline's dynamic arrays (pointer comparison; resolves to -1 when absent).
track_index_of :: proc(tr: ^Track) -> int {
	for ti in 0 ..< len(timeline.tracks) {
		if &timeline.tracks[ti] == tr {
			return ti
		}
	}
	return -1
}

clip_index_on_track :: proc(tr: ^Track, clip: ^Clip) -> int {
	for ci in 0 ..< len(tr.clips) {
		if &tr.clips[ci] == clip {
			return ci
		}
	}
	return -1
}

// is_clip_selected reports whether the clip at (track_idx, index) is part of the
// current selection: the anchor clip itself, or any member of the selected
// clip's link group. Highlighting every linked member makes a linked cut/move
// read as one unit instead of a lone border on the grabbed clip.
is_clip_selected :: proc(track_idx, index: int) -> bool {
	if track_idx == selection.track && index == selection.index {
		return true
	}
	if track_idx < 0 ||
	   track_idx >= len(timeline.tracks) ||
	   index < 0 ||
	   index >= len(timeline.tracks[track_idx].clips) {
		return false
	}
	candidate := &timeline.tracks[track_idx].clips[index]
	if candidate.clip_id in selection.extra_set {
		return true
	}
	_, sel, ok := selected_clip()
	if !ok || sel == nil || sel.link_id == 0 || candidate.link_id == 0 {
		return false
	}
	return candidate.link_id == sel.link_id
}

// find_clip_by_id locates the clip with the given clip_id across all tracks.
find_clip_by_id :: proc(id: u64) -> (^Track, ^Clip, bool) {
	for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
		tr := &timeline.tracks[track_idx]
		for i := 0; i < len(tr.clips); i += 1 {
			if tr.clips[i].clip_id == id {
				return tr, &tr.clips[i], true
			}
		}
	}
	return nil, nil, false
}

timeline_frame_at :: proc(frame: i64) -> Timeline_Frame {
	for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
		candidate_track := &timeline.tracks[track_idx]
		for i := 0; i < len(candidate_track.clips); i += 1 {
			candidate := &candidate_track.clips[i]
			if candidate.kind != .Video {
				continue
			}
			if clip_visible_at(frame, candidate.timeline_start_frame, candidate.source_length_frames) {
				return {
					active_clip = candidate,
					clip_frame = candidate.source_start_frame +
					frame -
					candidate.timeline_start_frame,
				}
			}
		}
	}
	return {}
}

// move_clip_to_track moves the clip at (src_track, src_index) onto dst_track at
// `start`, removing it from the source track. The placement is clamped so the
// clip never overlaps another clip on the destination track. Returns the
// clip's new index in dst_track, or -1 if the move was refused (no room).
move_clip_to_track :: proc(src_track, src_index: int, dst_track: int, start: i64) -> int {
	if src_track < 0 ||
	   src_track >= len(timeline.tracks) ||
	   dst_track < 0 ||
	   dst_track >= len(timeline.tracks) ||
	   src_track == dst_track {
		return -1
	}
	src := &timeline.tracks[src_track]
	if src_index < 0 || src_index >= len(src.clips) {
		return -1
	}
	clip := src.clips[src_index]
	dst := &timeline.tracks[dst_track]
	placed := clip_place_in_track(dst, -1, clip.source_length_frames, start)
	ordered_remove(&src.clips, src_index)
	append(&dst.clips, clip)
	dst.clips[len(dst.clips) - 1].timeline_start_frame = placed
	// Keep dst sorted by start for stable rendering.
	for i := len(dst.clips) - 1;
	    i > 0 && dst.clips[i].timeline_start_frame < dst.clips[i - 1].timeline_start_frame;
	    i -= 1 {
		dst.clips[i], dst.clips[i - 1] = dst.clips[i - 1], dst.clips[i]
	}
	// Refresh selection to the moved clip.
	selection.track = dst_track
	selection.index = len(dst.clips) - 1
	for i in 0 ..< len(dst.clips) {
		if dst.clips[i].timeline_start_frame == placed {
			selection.index = i
			break
		}
	}
	if vyper_trace {
		fmt.printf(
			"[tl] moved clip src=%s len=%d start=%d -> track %d @ %d\n",
			clip.path,
			clip.source_length_frames,
			start,
			dst_track,
			placed,
		)
	}
	// Cross-track moves change which clip covers the playhead: re-derive the
	// slots from the edited timeline instead of reusing the old covering state.
	invalidate_preview_slots()
	audio_note_edit()
	return selection.index
}

// clip_index_by_id returns the index of the clip with the given clip_id on the
// track, or -1. Edits elsewhere never invalidate this index (it is only stale if
// this same track's clip list changed).
clip_index_by_id :: proc(track: ^Track, id: u64) -> int {
	for i in 0 ..< len(track.clips) {
		if track.clips[i].clip_id == id {
			return i
		}
	}
	return -1
}

// drag_orig_of snapshots one clip's drag-time geometry into the record both
// capture paths (link group, ripple set) store.
drag_orig_of :: proc(clip: ^Clip, track: int) -> Drag_Group_Orig {
	return Drag_Group_Orig {
		clip_id = clip.clip_id,
		track = track,
		start = clip.timeline_start_frame,
		length = clip.source_length_frames,
	}
}

// capture_link_group snapshots the original (track, start, length) of every clip
// sharing clip's link_id into clip_move.group_orig, anchor first. Non-linked clips
// leave the array empty (len 0 = single-clip edit; len 1 = linked clip that is
// its own whole group, e.g. single-lane media). Call at gesture start, before any
// mutation: the captured originals are the invariant the group delta is computed
// against on every following frame.
capture_link_group :: proc(clip: ^Clip, track: int) {
	clear(&clip_move.group_orig)
	if clip.link_id == 0 {
		return
	}
	append(&clip_move.group_orig, drag_orig_of(clip, track))
	for t := 0; t < len(timeline.tracks); t += 1 {
		for i := 0; i < len(timeline.tracks[t].clips); i += 1 {
			c := &timeline.tracks[t].clips[i]
			if c.link_id == clip.link_id && c.clip_id != clip.clip_id {
				append(&clip_move.group_orig, drag_orig_of(c, t))
			}
		}
	}
}

// apply_group_drag_to_members shifts every non-anchor member by the anchor's
// live drag delta (anchor_delta = new anchor start - original anchor start).
// Members land EXACTLY at m.start + anchor_delta — no per-member clamping: the
// caller only ever reaches here when group_delta_feasible proved every member
// can land there (>= 0, no non-member overlap), and a member clamped against its
// own current neighbors would silently split the group (a same-track partner or
// a hard left-edge always clamps the same member short). Horizontal moves of a
// link group keep all members time-aligned with the anchor.
apply_group_drag_to_members :: proc(anchor_delta: i64) {
	if len(clip_move.group_orig) <= 1 {
		return
	}
	anchor_id := clip_move.group_orig[0].clip_id
	for m in clip_move.group_orig {
		if m.clip_id == anchor_id {
			continue
		}
		if m.track < 0 || m.track >= len(timeline.tracks) {
			continue
		}
		track := &timeline.tracks[m.track]
		idx := clip_index_by_id(track, m.clip_id)
		if idx < 0 {
			continue
		}
		track.clips[idx].timeline_start_frame = m.start + anchor_delta
	}
}

// capture_ripple_set snapshots every clip an Alt+drag will shift into
// clip_move.ripple_orig, anchor FIRST. Three sources, in capture order so the
// anchor is provably entry 0:
//
//	1. the anchor's whole link group (from group_orig, already captured);
//	2. the Shift multi-selection (selection.extra_set);
//	3. every remaining clip on every track whose start is at or after the
//	   ANCHOR's own start — that is the ripple proper.
//
// (1) and (2) join outright even when they start earlier than the threshold: a
// link partner left behind is the desync every group move exists to prevent,
// and a clip the user explicitly Shift-clicked into the group is not theirs to
// strand. The threshold is the ANCHOR rather than the earliest member, so
// moving a late clip on an early-starting group does not drag the whole tail
// of the timeline with it.
//
// Call at gesture start, before any mutation, right after capture_link_group.
capture_ripple_set :: proc(clip: ^Clip, track: int) {
	clear(&clip_move.ripple_orig)
	threshold := clip.timeline_start_frame
	append(&clip_move.ripple_orig, drag_orig_of(clip, track))
	for m in clip_move.group_orig {
		if m.clip_id != clip.clip_id {
			append(&clip_move.ripple_orig, m)
		}
	}
	for id in selection.extra_set {
		if id == clip.clip_id {
			continue
		}
		if tr, c, ok := find_clip_by_id(id); ok {
			append(&clip_move.ripple_orig, drag_orig_of(c, track_index_of(tr)))
		}
	}
	for t := 0; t < len(timeline.tracks); t += 1 {
		for &c in timeline.tracks[t].clips {
			if c.timeline_start_frame >= threshold && !ripple_moves_clip(c.clip_id) {
				append(&clip_move.ripple_orig, drag_orig_of(&c, t))
			}
		}
	}
}

// ripple_moves_clip reports whether the clip is part of the captured ripple set.
// Clip ids are unique across the whole timeline (find_clip_by_id resolves on the
// id alone), so one linear scan of the set is the whole answer — and skipping
// the membership map the group helpers build keeps the per-frame path
// allocation-free.
ripple_moves_clip :: proc(id: u64) -> bool {
	for &m in clip_move.ripple_orig {
		if m.clip_id == id {
			return true
		}
	}
	return false
}

// ripple_clamp_delta bounds the ripple's shared delta from below. Because ALL
// the captured clips shift by the same delta, every pair inside the set keeps
// its relative geometry and can never collide — so the only walls are between a
// moving clip and a clip that does NOT move, and there is only ever ONE side of
// them: a non-member starts before the anchor's threshold by definition, hence
// before every member's start, so it can only ever sit to a member's LEFT.
// There is no right-hand wall to compute, and writing one would be code that
// can never fire.
//
// The floor is the tightest of two things: the timeline's left edge (no member
// may start before frame 0 — the same left-edge rule group_delta_feasible
// enforces, expressed as a bound instead of a refusal because every member of a
// ripple shares one delta by construction), and each non-member's tail, so the
// set parks FLUSH against the binding wall instead of driving through it.
//
// Walls are read off each pair's CURRENT relationship, the same rule
// group_clamp_delta uses, and a pair that ALREADY overlaps contributes nothing.
// That is not a gap in the rule, it is the point: this timeline permits
// same-track overlap for stacked clips, so a straddler is a legitimate state.
// The ripple neither deepens an overlap that was already there nor tries to
// resolve one the user did not ask it to.
ripple_clamp_delta :: proc(delta: i64) -> i64 {
	if len(clip_move.ripple_orig) == 0 {
		return delta
	}
	lo := -(i64(1) << 40)
	for m in clip_move.ripple_orig {
		lo = max(lo, -m.start)
		if m.track < 0 || m.track >= len(timeline.tracks) {
			continue
		}
		for &c in timeline.tracks[m.track].clips {
			if ripple_moves_clip(c.clip_id) {
				continue
			}
			cend := c.timeline_start_frame + c.source_length_frames
			if cend <= m.start {
				lo = max(lo, cend - m.start)
			}
		}
	}
	return max(delta, lo)
}

apply_ripple_drag :: proc(delta: i64) {
	for m in clip_move.ripple_orig {
		if m.track < 0 || m.track >= len(timeline.tracks) {
			continue
		}
		t := &timeline.tracks[m.track]
		i := clip_index_by_id(t, m.clip_id)
		if i < 0 {
			continue
		}
		t.clips[i].timeline_start_frame = m.start + delta
	}
}

// group_delta_feasible reports whether every captured link-group member can
// land on its OWN lane at exactly m.start + delta (all moving together by
// delta, members vacating their originals simultaneously) without overlapping
// any NON-member clip. A group drag only ever advances to deltas that are
// feasible for every member: the anchor must never move into a slot a partner
// cannot reach.
group_delta_feasible :: proc(delta: i64) -> bool {
	if len(clip_move.group_orig) <= 1 {
		return true
	}
	members := make(map[u64]bool, len(clip_move.group_orig), context.temp_allocator)
	for m in clip_move.group_orig {
		members[m.clip_id] = true
	}
	for m in clip_move.group_orig {
		if m.track < 0 || m.track >= len(timeline.tracks) {
			return false
		}
		t := &timeline.tracks[m.track]
		ts := m.start + delta
		if ts < 0 {
			// A member would land before the timeline start: the whole group
			// must not advance (an exact-landing member clamp would split it).
			return false
		}
		for &c in t.clips {
			if c.clip_id in members {
				continue
			}
			if ts < clip_timeline_end(c) && c.timeline_start_frame < ts + m.length {
				return false
			}
		}
	}
	return true
}

// group_clamp_delta clamps a group-drag delta to the nearest position every
// captured member can land at, WITHOUT any member crossing its nearest
// non-member blocker: the group parks FLUSH against the binding member's wall.
// A group flick is lockstep — the feasibility gate never moves members to an
// exact infeasible delta — so a fast cursor jump that overshoots a wall used
// to FREEZE the whole group at the last sampled target (possibly many frames
// short of the wall), with the cursor flying past while the anchor sits in
// open band: "drag cut short before touching." Clamping to the current
// interval's walls makes a fast and a slow drag park at the same flush spot.
// The walls are the blockers at-or-left / at-or-right of each member's CURRENT
// position, so the clamp never jumps a band (matching single-clip behavior).
group_clamp_delta :: proc(delta: i64) -> i64 {
	if len(clip_move.group_orig) <= 1 {
		return delta
	}
	members := make(map[u64]bool, len(clip_move.group_orig), context.temp_allocator)
	for m in clip_move.group_orig {
		members[m.clip_id] = true
	}
	d_cur := clip_move.clip.timeline_start_frame - clip_move.group_orig[0].start
	lo, hi := i64(-1 << 40), i64(1 << 40)
	for m in clip_move.group_orig {
		if m.track < 0 || m.track >= len(timeline.tracks) {
			return delta
		}
		t := &timeline.tracks[m.track]
		ts := m.start + d_cur
		mlow := -m.start
		mhigh := i64(1 << 40)
		for &c in t.clips {
			if c.clip_id in members {
				continue
			}
			cend := c.timeline_start_frame + c.source_length_frames
			if cend <= ts {
				mlow = max(mlow, cend - m.start)
			}
			if ts + m.length <= c.timeline_start_frame {
				mhigh = min(mhigh, c.timeline_start_frame - m.start - m.length)
			}
		}
		lo = max(lo, mlow)
		hi = min(hi, mhigh)
	}
	if hi < lo {
		return delta
	}
	return clamp(delta, lo, hi)
}

// group_vertical_feasible reports whether every captured link-group member can
// land on a destination lane `track_delta_visual` rows away in the visual stack
// at the mouse-aligned position m.start + delta (clamped to >= 0) without
// overlapping a non-member clip there.  track_delta_visual is the row distance
// in the ORDERED stack (positive = downward), not a storage-index delta --
// the group may span non-adjacent storage indices, but the overlap checks
// target the correct destination track.
group_vertical_feasible :: proc(track_delta_visual: int, delta: i64) -> bool {
	if len(clip_move.group_orig) == 0 {
		return false
	}
	sync_track_order()
	members := make(map[u64]bool, len(clip_move.group_orig), context.temp_allocator)
	for m in clip_move.group_orig {
		members[m.clip_id] = true
	}
	for m in clip_move.group_orig {
		src_row := order_row_of(m.track)
		if src_row < 0 {
			return false
		}
		dst := track_at_row(src_row + track_delta_visual)
		if dst < 0 {
			return false
		}
		ts := m.start + delta
		if ts < 0 {
			return false
		}
		for &c in timeline.tracks[dst].clips {
			if c.clip_id in members {
				continue
			}
			if ts < clip_timeline_end(c) && c.timeline_start_frame < ts + m.length {
				return false
			}
		}
	}
	return true
}

// move_linked_group relocates every clip captured in clip_move.group_orig by
// track_delta_visual rows in the visual stack (the anchor's vertical drop),
// keeping each member laid-out at the same mouse-aligned horizontal offset the
// ghost showed: start = m.start + clip_move.group_delta. Refused (returns false,
// nothing moves) unless EVERY member can land at that exact spot on its
// destination lane without overlapping a non-member clip, then re-selects the
// anchor in its new home.
move_linked_group :: proc(track_delta_visual: int) -> bool {
	if track_delta_visual == 0 || len(clip_move.group_orig) == 0 {
		return false
	}
	sync_track_order()
	if !group_vertical_feasible(track_delta_visual, clip_move.group_delta) {
		return false
	}
	PlannedMove :: struct {
		src_track, dst_track: int,
		start:                i64,
		clip:                 Clip,
	}
	planned := make([dynamic]PlannedMove, 0, len(clip_move.group_orig), context.temp_allocator)
	for m in clip_move.group_orig {
		src_row := order_row_of(m.track)
		if src_row < 0 {
			return false
		}
		dst := track_at_row(src_row + track_delta_visual)
		if dst < 0 {
			return false
		}
		src := &timeline.tracks[m.track]
		idx := clip_index_by_id(src, m.clip_id)
		if idx < 0 {
			continue
		}
		clip := src.clips[idx]
		start := m.start + clip_move.group_delta
		append(
			&planned,
			PlannedMove{src_track = m.track, dst_track = dst, start = start, clip = clip},
		)
	}
	// Commit every relocation. Source indices captured at planning time are NOT
	// reusable here: appending one member into another member's destination lane
	// re-sorts that track and shifts its clips, so a cached src_index would make
	// ordered_remove delete the wrong clip (the member it displaced kept its
	// place while the anchor vanished). Always re-locate each member's source by
	// clip_id immediately before removal -- same rule resize_group_* already use.
	for p in planned {
		src := &timeline.tracks[p.src_track]
		idx := clip_index_by_id(src, p.clip.clip_id)
		if idx < 0 {
			continue
		}
		ordered_remove(&src.clips, idx)
		clip := p.clip
		clip.timeline_start_frame = p.start
		dst := &timeline.tracks[p.dst_track]
		append(&dst.clips, clip)
		for i := len(dst.clips) - 1;
		    i > 0 && dst.clips[i].timeline_start_frame < dst.clips[i - 1].timeline_start_frame;
		    i -= 1 {
			dst.clips[i], dst.clips[i - 1] = dst.clips[i - 1], dst.clips[i]
		}
	}
	invalidate_preview_slots()
	audio_note_edit()
	// Re-select the anchor in its new home.
	for t := 0; t < len(timeline.tracks); t += 1 {
		for i := 0; i < len(timeline.tracks[t].clips); i += 1 {
			if timeline.tracks[t].clips[i].clip_id == clip_move.group_orig[0].clip_id {
				selection.track = t
				selection.index = i
			}
		}
	}
	return true
}

// resize_group_right resizes the whole link group's right edge to new_tail: the
// anchor clip is resized exactly as a single clip, then every other member's
// tail moves by the same delta, each clamped to its own lane/source. Returns the
// anchor's applied length. No-op for unlinked clips (clip_move.group_orig empty).
resize_group_right :: proc(track: ^Track, idx: int, new_tail: i64) -> i64 {
	applied := resize_clip_right(track, idx, new_tail)
	if len(clip_move.group_orig) == 0 || clip_move.group_orig[0].clip_id != track.clips[idx].clip_id {
		return applied
	}
	delta := applied - clip_move.group_orig[0].length
	for m in clip_move.group_orig {
		if m.clip_id == clip_move.group_orig[0].clip_id {
			continue
		}
		if m.track < 0 || m.track >= len(timeline.tracks) {
			continue
		}
		dst := &timeline.tracks[m.track]
		mi := clip_index_by_id(dst, m.clip_id)
		if mi < 0 {
			continue
		}
		resize_clip_right(dst, mi, m.start + m.length + delta)
	}
	return applied
}

// resize_group_left moves the whole link group's head: the anchor clip's head is
// moved exactly as a single clip, then every other member's head shifts by the
// same delta, each clamped to its own lane/source. The tail stays anchored, so
// members don't drift relative to each other. Returns the anchor's applied
// length. No-op for unlinked clips.
resize_group_left :: proc(track: ^Track, idx: int, new_head: i64) -> i64 {
	applied := resize_clip_left(track, idx, new_head)
	if len(clip_move.group_orig) == 0 || clip_move.group_orig[0].clip_id != track.clips[idx].clip_id {
		return applied
	}
	delta := track.clips[idx].timeline_start_frame - clip_move.group_orig[0].start
	for m in clip_move.group_orig {
		if m.clip_id == clip_move.group_orig[0].clip_id {
			continue
		}
		if m.track < 0 || m.track >= len(timeline.tracks) {
			continue
		}
		dst := &timeline.tracks[m.track]
		mi := clip_index_by_id(dst, m.clip_id)
		if mi < 0 {
			continue
		}
		resize_clip_left(dst, mi, m.start + delta)
	}
	return applied
}

// next_track_name returns "Track N" with N one greater than the largest "Track N"
// number already present, so names stay unique.
next_track_name :: proc() -> string {
	next := len(timeline.tracks) + 1
	for existing in timeline.tracks {
		if len(existing.name) > len("Track ") {
			n, ok := strconv.parse_int(existing.name[len("Track "):], 10)
			if ok && n >= next {
				next = n + 1
			}
		}
	}
	return fmt.aprintf("Track %d", next)
}

// sync_track_order restores the invariant that track_order is a permutation of
// [0 .. len(tracks)) in top-to-bottom order. The mutators below keep that
// invariant explicitly; direct `append(&timeline.tracks, ...)` sites (media
// lane creation, probes) rely on this lazily rebuilding the missing tail in
// storage order, which is exactly bottom-append semantics. Cheap when already
// consistent, so order consumers (UI rows, preview walk, render) can call it
// every frame without thinking.
sync_track_order :: proc() {
	// Direct `append(&timeline.tracks, ...)` sites (media lane creation,
	// probes) grow storage without touching the order, and they only ever add
	// a new max index at the bottom -- extending the missing tail in storage
	// order is exactly those bottom-append semantics. Every other mutator
	// (insert_track, move_track_to_row, duplicate_track, remove_track) keeps
	// track_order a permutation of [0 .. len(tracks)) explicitly, so a length
	// mismatch here is a mutator that dropped that invariant -- a bug, not a
	// state to silently rebuild.
	for len(timeline.track_order) < len(timeline.tracks) {
		append(&timeline.track_order, len(timeline.track_order))
	}
	assert(
		len(timeline.track_order) == len(timeline.tracks),
		"sync_track_order: track_order longer than tracks",
	)
	// Length alone does not make it a permutation. Appending the missing tail
	// assumes every existing entry is a DISTINCT index below len(tracks); an
	// order that already repeats one silently omits another, and the omitted
	// track then vanishes from every walk that goes through track_order -- the
	// export compositor included, which renders a track's clips as if they were
	// not on the timeline at all. That is a quiet wrong answer, so it is checked
	// here rather than at each consumer.
	//
	// Checked as "every value is in range AND appears exactly once", which with
	// the length assert above is exactly a permutation. Counted in place rather
	// than sorted into a scratch slice: sync_track_order runs on rendering and
	// mutation paths, and an assert must not be the thing that allocates.
	for a in timeline.track_order {
		assert(
			a >= 0 && a < len(timeline.tracks),
			"sync_track_order: track_order holds an out-of-range track index",
		)
		seen := 0
		for b in timeline.track_order {
			if b == a {
				seen += 1
			}
		}
		assert(
			seen == 1,
			"sync_track_order: track_order is not a permutation of the tracks (duplicate or gap)",
		)
	}
}

// order_row_of returns the top-to-bottom row (position in track_order) of the
// track at STORAGE index ti, or -1 if it isn't in the order. Note Odin's range
// is (value, index) — the loop body destructures storage_idx, row.
order_row_of :: proc(ti: int) -> int {
	for storage_idx, row in timeline.track_order {
		if storage_idx == ti {
			return row
		}
	}
	return -1
}

// track_at_row returns the STORAGE index of the track displayed at visual row
// r, or -1 when r is outside the stack. All "N rows from X" math (clip drops,
// group moves, ghost drawing) goes through this so the translation storage==
// visual-order that used to be implicit in the array is explicit and correct
// under any order.
track_at_row :: proc(r: int) -> int {
	if r < 0 || r >= len(timeline.track_order) {
		return -1
	}
	return timeline.track_order[r]
}

// insert_track inserts a new empty track at visual position order_pos in the
// track stack (0 = topmost, len = bottom): the row appears where the gap it
// was clicked sits, and every row below shifts down. Storage is append-only,
// so existing STORAGE indices (selection.track, drag targets) never move.
insert_track :: proc(order_pos: int) {
	undo_begin()
	sync_track_order()
	append(&timeline.tracks, Track {name = next_track_name()})
	new_ti := len(timeline.tracks) - 1
	pos := clamp(order_pos, 0, len(timeline.track_order))
	inject_at_elem(&timeline.track_order, pos, new_ti)
	undo_push(.Track, "Add track")
}

// move_track_to_row moves the track at STORAGE index `ti` so it occupies the
// visual stack position `target_row` (0 = top, len(track_order) = bottom,
// matching insert_track's order_pos and the gap keys the drag hovers).
// Storage stays append-only -- the track array never moves -- so selection.track
// and other STORAGE indices remain valid; only track_order changes.
//
// target_row == src_row is the track's own gap (no move) and target_row ==
// src_row+1 is the gap immediately below it (the row already borders that gap,
// so a swap in would be a no-op) -- both early-return. For any other target,
// remove the source first: rows below it shift up one, so inserting below the
// source lands one index earlier in the reduced order.
//
// Reordering changes which track paints on top, so the preview slots are
// invalidated (slots' layer comes from the stack order).
move_track_to_row :: proc(ti: int, target_row: int) {
	sync_track_order()
	if ti < 0 || ti >= len(timeline.tracks) {
		return
	}
	src_row := order_row_of(ti)
	if src_row < 0 {
		return
	}
	// Negative target = "not over a gap" (drag cancelled); never clamp that
	// into a move-to-top. Real gaps are always clamped into range below.
	if target_row < 0 {
		return
	}
	target := clamp(target_row, 0, len(timeline.track_order))
	if target == src_row || target == src_row + 1 {
		return
	}
	undo_begin()
	ordered_remove(&timeline.track_order, src_row)
	// After the source is gone rows below it shifted up one, so a target below
	// the source lands one index earlier in the reduced order.
	insert_at := target
	if target > src_row {
		insert_at -= 1
	}
	inject_at_elem(&timeline.track_order, insert_at, ti)
	invalidate_preview_slots()
	undo_push(.Track, fmt.tprintf("Reorder track \"%s\"", timeline.tracks[ti].name))
}

// duplicate_track inserts a copy of the track directly ABOVE the original (one
// row up in the visual stack), copying clip POD records into a new dynamic array.
// Session ranges share until first write. The copy lands adjacent to its
// source no matter where the source sits on the stack -- it never jumps over
// unrelated tracks to the very top, which is what silently reordered rows and
// left the duplicated video stacked above things the user wasn't looking at.
duplicate_track :: proc(index: int) {
	undo_begin()
	sync_track_order()
	src := &timeline.tracks[index]
	new_track := Track {
		name = next_track_name(),
		// Clip records persist on the inserted track.
		clips = make([dynamic]Clip, 0, len(src.clips)),
	}
	// A duplicated clip is a NEW clip instance: mint a fresh identity so
	// update_preview_slots claims its own slot instead of collapsing into the
	// original's (same clip_id = same slot = the original's transform/layer
	// wins and the copy's content never paints). Sever the link group too, so
	// selecting a duplicate never drags the original's partner tracks along.
	//
	// Share pooled ranges explicitly; first marker/key write separates only the
	// touched range. Scalar fields and immutable string handles copy by value.
	for i in 0 ..< len(src.clips) {
		c := src.clips[i]
		c.markers = session_marker_share(&src.clips[i].markers)
		c.keyframe_tracks = session_trk_share(&src.clips[i].keyframe_tracks)
		c.clip_id = new_clip_id()
		c.link_id = 0
		append(&new_track.clips, c)
	}
	append(&timeline.tracks, new_track)
	new_ti := len(timeline.tracks) - 1
	// ABOVE the source: inject at the source's own row so the copy takes the
	// source's slot in the visual stack and the original shifts down one.
	src_row := order_row_of(index)
	pos := clamp(src_row, 0, len(timeline.track_order))
	inject_at_elem(&timeline.track_order, pos, new_ti)
	undo_push(.Duplicate, fmt.tprintf("Duplicate track \"%s\"", src.name))
}

// duplicate_clip inserts a COW copy of the clip at (track_idx,index)
// on the same track, placed in the nearest free slot directly after the
// original, and returns new index. It gets a fresh identity and link group.
duplicate_clip :: proc(track_idx, index: int) -> int {
	undo_begin()
	track := &timeline.tracks[track_idx]
	src := &track.clips[index]
	// Clip is POD; share pooled ranges after the value copy.
	c := src^
	c.markers = session_marker_share(&src.markers)
	c.keyframe_tracks = session_trk_share(&src.keyframe_tracks)
	c.clip_id = new_clip_id()
	c.link_id = 0
	place := clip_timeline_end(src^)
	c.timeline_start_frame = clip_place_in_track(track, index, c.source_length_frames, place)
	insert_at := index + 1
	for insert_at < len(track.clips) &&
	    track.clips[insert_at].timeline_start_frame < c.timeline_start_frame {
		insert_at += 1
	}
	inject_at_elem(&track.clips, insert_at, c)
	undo_push(.Duplicate, "Duplicate clip")
	return insert_at
}

// remove_track deletes the track at index (and all of its clips) from the
// timeline. Releases exclusive session ranges and track-owned arrays, clears or
// adjusts the saved selection (clips on other tracks keep their indices, so
// selection.index is preserved), and invalidates the preview/audio state the
// way every clip-delete path must (see delete_selected_clip_raw).
remove_track :: proc(index: int) {
	sync_track_order()
	if index < 0 || index >= len(timeline.tracks) {
		return
	}
	undo_begin()
	removed := timeline.tracks[index]
	for &c in removed.clips {
		clip_ranges_release(&c)
	}
	delete(removed.clips)
	name_buf: [128]u8
	label := fmt.bprintf(name_buf[:], "Remove track \"%s\"", removed.name)
	delete(removed.name)
	ordered_remove(&timeline.tracks, index)
	// Drop the removed track from the visual stack and renumber every entry
	// above it (track_order is a permutation, so this keeps it one).
	for w := 0; w < len(timeline.track_order); w += 1 {
		switch {
		case timeline.track_order[w] == index:
			ordered_remove(&timeline.track_order, w)
			w -= 1
		case timeline.track_order[w] > index:
			timeline.track_order[w] -= 1
		}
	}
	switch {
	case selection.track == index:
		selection.track = -1
		selection.index = -1
	case selection.track > index:
		selection.track -= 1
	}
	active_interaction = .None
	clip_move.clip = nil
	clip_move.source_track = -1
	clip_move.source_index = -1
	clip_move.hover_track = -1
	// CRITICAL: the removed clips' decoded frames/decoders/GPU textures must be
	// dropped or they keep painting at the playhead. Same rule as any delete.
	invalidate_preview_slots()
	audio_note_edit()
	undo_push(.Track, label)
	return
}
