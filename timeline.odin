package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:sync"

// ---------------------------------------------------------------------------
// Timeline queries and structural edits: duration/ruler math, frame lookups,
// selection, and track insert/duplicate/naming.
// ---------------------------------------------------------------------------

clip_timeline_end :: proc(clip: Clip) -> i64 { return clip.timeline_start_frame + clip.source_length_frames }

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
		defer delete(gaps)
		if gi := gap_for_start(gaps[:], start); gi >= 0 {
			hi := gaps[gi][1]
			if start + length > hi {
				length = clamp(hi - start, 1, length)
			}
		}
	}
	clip := Clip{
		clip_id = new_clip_id(),
		asset_id = 0,
		path = nil,
		kind = .Text,
		generator = .Text,
		stream_index = -1,
		source_start_frame = 0,
		source_length_frames = length,
		timeline_start_frame = start,
		transform_x = f32(project.width) / 2,
		transform_y = f32(project.height) / 2,
		scale = 1,
		crop_l = 0,
		crop_r = 0,
		crop_t = 0,
		crop_b = 0,
	}
	append(&track.clips, clip)
	// Keep the track's clips sorted ascending by timeline start.
	idx := len(track.clips) - 1
	for i := idx; i > 0 && track.clips[i].timeline_start_frame < track.clips[i-1].timeline_start_frame; i -= 1 {
		track.clips[i], track.clips[i-1] = track.clips[i-1], track.clips[i]
		idx = i - 1
	}
	return idx
}

// clip_track_gaps returns the free (non-covered) bands of `track`, ignoring the
// clip at exclude_idx (-1 = include everything). The trailing band is unbounded
// so clips may still extend the timeline. Caller must delete the result.
clip_track_gaps :: proc(track: ^Track, exclude_idx: int) -> [dynamic][2]i64 {
	gaps := make([dynamic][2]i64, 0, len(track.clips) + 1)
	if len(track.clips) == 0 {
		append(&gaps, [2]i64{0, max(0, i64(1 << 40))})
		return gaps
	}
	covered := make([dynamic][2]i64, 0, len(track.clips))
	defer delete(covered)
	for i in 0 ..< len(track.clips) {
		if i == exclude_idx {
			continue
		}
		c := track.clips[i]
		append(&covered, [2]i64{c.timeline_start_frame, clip_timeline_end(c)})
	}
	for i in 1 ..< len(covered) {
		for j := i; j > 0 && covered[j][0] < covered[j-1][0]; j -= 1 {
			covered[j], covered[j-1] = covered[j-1], covered[j]
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
	defer delete(gaps)
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
clip_slide_in_track :: proc(track: ^Track, exclude_idx: int, clip_len: i64, desired, anchor: i64) -> i64 {
	if clip_len <= 0 {
		return desired
	}
	if len(track.clips) == 0 {
		return max(desired, 0)
	}
	gaps := clip_track_gaps(track, exclude_idx)
	defer delete(gaps)
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
// two adjacent clips at that frame (the frame stays with the left half). Both
// halves keep their in-range markers; the right half is inserted right after the
// left so the two touch.
split_clip_at_playhead :: proc() {
	tr: ^Track
	clip: ^Clip
	ok := false
	tr, clip, ok = selected_clip()
	if !ok {
		return
	}
	frame := playhead.frame
	local := frame - clip.timeline_start_frame
	if local <= 0 || local >= clip.source_length_frames {
		return
	}
	sync.mutex_lock(&audio_timeline_mtx)
	defer sync.mutex_unlock(&audio_timeline_mtx)
	left_len := local
	right_len := clip.source_length_frames - local
	right := clip^
	clip.source_length_frames = left_len
	clip.markers = filter_markers_in_range(clip.markers[:], clip.source_start_frame, clip.source_length_frames)
	right.source_start_frame += local
	right.source_length_frames = right_len
	right.timeline_start_frame = frame
	right.markers = filter_markers_in_range(right.markers[:], right.source_start_frame, right.source_length_frames)
	idx := -1
	for i := 0; i < len(tr.clips); i += 1 {
		if &tr.clips[i] == clip {
			idx = i
			break
		}
	}
	if idx < 0 {
		return
	}
	inject_at_elem(&tr.clips, idx + 1, right)
	if nered_trace {
		fmt.printf("[tl] split selected clip@%d src=%d len %d -> %d | %d..%d\n",
			clip.timeline_start_frame, clip.source_start_frame,
			left_len, right_len, right.timeline_start_frame, right.timeline_start_frame+right_len)
	}
	audio_note_edit()
}

// filter_markers_in_range returns a new dynamic array with the markers whose
// source_frame lies in [start, start+length).
filter_markers_in_range :: proc(markers: []Clip_Marker, start, length: i64) -> [dynamic]Clip_Marker {
	out := make([dynamic]Clip_Marker)
	for m in markers {
		if m.source_frame >= start && m.source_frame < start + length {
			append(&out, m)
		}
	}
	return out
}

// delete_selected_clip_raw removes just the selected clip from its track. No
// ripple, no region removal, no other clips/tracks affected: the timeline
// simply stops showing this clip (a gap stays where it was).
delete_selected_clip_raw :: proc() {
	if selected_track < 0 || selected_track >= len(timeline.tracks) {
		return
	}
	track := &timeline.tracks[selected_track]
	if selected_index < 0 || selected_index >= len(track.clips) {
		return
	}
	sync.mutex_lock(&audio_timeline_mtx)
	removed := track.clips[selected_index]
	ordered_remove(&track.clips, selected_index)
	sync.mutex_unlock(&audio_timeline_mtx)
	delete(removed.markers)
	if nered_trace {
		fmt.printf("[tl] deleted clip raw src=%s start=%d len=%d\n",
			removed.path, removed.timeline_start_frame, removed.source_length_frames)
	}
	selected_track = -1
	selected_index = -1
	// CRITICAL: invalidation MUST follow every delete. The timeline no longer
	// references `removed`, but the per-clip preview slots still hold this
	// clip's decoded frames, open decoder, and GPU texture. Without
	// invalidate_preview_slots the deleted clip keeps painting at the playhead
	// (classic "deleted clip still renders" bug). Do not remove this regardless
	// of how the delete is wired — any new delete path must do the same.
	moving_clip = false
	moving_preview_clip = false
	drag_clip = nil
	drag_source_track = -1
	drag_source_index = -1
	drag_hover_track = -1
	invalidate_preview_slots()
	audio_note_edit()
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
	end := start + length
	sync.mutex_lock(&audio_timeline_mtx)
	defer sync.mutex_unlock(&audio_timeline_mtx)
	for ti in 0 ..< len(timeline.tracks) {
		track := &timeline.tracks[ti]
		new_clips := make([dynamic]Clip, 0, len(track.clips))
		for i in 0 ..< len(track.clips) {
			c := track.clips[i]
			cs := c.timeline_start_frame
			ce := clip_timeline_end(c)
			switch {
			case ce <= start:
				// Entirely before the region: untouched (keeps the original
				// markers slice: the new copy still references it).
				append(&new_clips, c)
			case cs >= end:
				// Entirely after the region: slide left to close the gap.
				c.timeline_start_frame -= length
				append(&new_clips, c)
			case cs < start && ce > end:
				// Straddles the whole region: split into left + right pieces.
				left := c
				left.source_length_frames = start - cs
				left.markers = filter_markers_in_range(left.markers[:], left.source_start_frame, left.source_length_frames)
				append(&new_clips, left)
				right := c
				right.source_start_frame += end - cs
				right.source_length_frames = ce - end
				right.timeline_start_frame = start
				right.markers = filter_markers_in_range(right.markers[:], right.source_start_frame, right.source_length_frames)
				append(&new_clips, right)
				// Original markers array no longer referenced by any copy.
				delete(c.markers)
			case cs < start:
				// Overlaps the left edge only: trim its tail.
				old_markers := c.markers
				c.source_length_frames = start - cs
				c.markers = filter_markers_in_range(old_markers[:], c.source_start_frame, c.source_length_frames)
				append(&new_clips, c)
				delete(old_markers)
			case ce > end:
				// Overlaps the right edge only: trim its head, shifted to start.
				old_markers := c.markers
				c.source_start_frame += cs - start
				c.source_length_frames = ce - end
				c.timeline_start_frame = start
				c.markers = filter_markers_in_range(old_markers[:], c.source_start_frame, c.source_length_frames)
				append(&new_clips, c)
				delete(old_markers)
			case cs >= start && ce <= end:
				// Otherwise the clip is entirely inside the region: dropped.
				delete(c.markers)
			}
		}
		delete(track.clips)
		track.clips = new_clips
	}
	// The edit may have removed/replaced the dragged clip and the decoded state
	// cached for it: cancel any in-flight drag and drop the preview slots so the
	// next update re-derives them purely from the edited timeline.
	moving_clip = false
	moving_preview_clip = false
	drag_clip = nil
	drag_source_track = -1
	drag_source_index = -1
	drag_hover_track = -1
	invalidate_preview_slots()
	if nered_trace {
		fmt.printf("[tl] ripple delete region [%d, %d)\n", start, end)
	}
	selected_track = -1
	selected_index = -1
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
	if selected_track >= 0 && selected_track < len(timeline.tracks) {
		tr := &timeline.tracks[selected_track]
		if selected_index >= 0 && selected_index < len(tr.clips) {
			return tr, &tr.clips[selected_index], true
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
			if frame >= candidate.timeline_start_frame && frame < candidate.timeline_start_frame + candidate.source_length_frames {
				return {active_clip = candidate, clip_frame = candidate.source_start_frame + frame - candidate.timeline_start_frame}
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
	if src_track < 0 || src_track >= len(timeline.tracks) ||
		dst_track < 0 || dst_track >= len(timeline.tracks) ||
		src_track == dst_track {
		    return -1
	    }
	    src := &timeline.tracks[src_track]
	    if src_index < 0 || src_index >= len(src.clips) {
		    return -1
	    }
	    clip := src.clips[src_index]
	    dst := &timeline.tracks[dst_track]
	    sync.mutex_lock(&audio_timeline_mtx)
	    placed := clip_place_in_track(dst, -1, clip.source_length_frames, start)
	    ordered_remove(&src.clips, src_index)
	    append(&dst.clips, clip)
	    dst.clips[len(dst.clips)-1].timeline_start_frame = placed
	    // Keep dst sorted by start for stable rendering.
	    for i := len(dst.clips) - 1; i > 0 && dst.clips[i].timeline_start_frame < dst.clips[i-1].timeline_start_frame; i -= 1 {
		    dst.clips[i], dst.clips[i-1] = dst.clips[i-1], dst.clips[i]
	    }
	    sync.mutex_unlock(&audio_timeline_mtx)
	    // Refresh selection to the moved clip.
	    selected_track = dst_track
	    selected_index = len(dst.clips) - 1
	    for i in 0 ..< len(dst.clips) {
		    if dst.clips[i].timeline_start_frame == placed {
			    selected_index = i
			    break
		    }
	    }
	    if nered_trace {
		    fmt.printf("[tl] moved clip src=%s len=%d start=%d -> track %d @ %d\n",
			    clip.path, clip.source_length_frames, start, dst_track, placed)
	    }
	    // Cross-track moves change which clip covers the playhead: re-derive the
	    // slots from the edited timeline instead of reusing the old covering state.
	    invalidate_preview_slots()
	    audio_note_edit()
	    return selected_index
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

// insert_track inserts a new empty track at the given index (0-based) in the
// timeline track list — e.g. between existing tracks.
insert_track :: proc(index: int) {
	track := Track{name = next_track_name()}
	inject_at_elem(&timeline.tracks, index, track)
}

// duplicate_track inserts a copy of the track at index directly below the
// original (index + 1), deep-copying every clip into a new dynamic array so the
// two tracks are fully independent.
duplicate_track :: proc(index: int) {
	src := &timeline.tracks[index]
	new_track := Track{
		name = next_track_name(),
		layer = src.layer,
		clips = make([dynamic]Clip, 0, len(src.clips)),
	}
	for c in src.clips {
		append(&new_track.clips, c)
	}
	inject_at_elem(&timeline.tracks, index + 1, new_track)
}
