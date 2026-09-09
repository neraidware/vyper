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

// add_subtitle_generator_clip inserts a Subtitle generator clip (kind .Text,
// generator .Subtitles) backed by the parsed srt at cache index src_id on
// `track`, starting at `start_frame`. The natural length is the srt's full
// authored span (never shorter than one second), gap-fitted like the text clip
// (shortened to fit the free gap if it can't hold the whole span; never
// shifted). The caller owns `name` (cloned from the srt's basename downstream).
add_subtitle_generator_clip :: proc(track: ^Track, start_frame: i64, src_id: int, name: string) -> int {
	one_sec := i64(math.round(timeline_fps()))
	start := max(start_frame, 0)
	src := srt_source(src_id)
	length := max(one_sec, cue_frame(srt_duration_ms(src), f32(timeline_fps())))
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
		name = name,
		kind = .Text,
		generator = .Subtitles,
		srt_id = src_id,
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
// (playhead, clip start/end) for the drag/scrub to latch, expressed in frames
// from the fixed pixel margin so it scales with zoom.
snap_margin_frames :: proc() -> i64 {
	return max(i64(SNAP_PIXELS / timeline_zoom), 1)
}

// snap_to_playhead latches a clip-drag target onto the playhead when it comes
// within the snap margin. Used by the clip→playhead toggle.
snap_to_playhead :: proc(frame: i64) -> i64 {
	if frame == playhead.frame {
		return frame
	}
	if abs(frame - playhead.frame) <= snap_margin_frames() {
		return playhead.frame
	}
	return frame
}

// snap_playhead_to_clip_edge latches a scrubbed playhead onto the nearest clip
// start or end frame that falls within the snap margin. Used by the
// playhead→clip toggle.
snap_playhead_to_clip_edge :: proc(frame: i64) -> i64 {
	best := frame
	best_dist := i64(0)
	m := snap_margin_frames()
	for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
		for index := 0; index < len(timeline.tracks[track_idx].clips); index += 1 {
			c := &timeline.tracks[track_idx].clips[index]
			start := c.timeline_start_frame
			end := start + c.source_length_frames
			dist := abs(frame - start)
			if dist <= m && (best == frame || dist < best_dist) {
				best = start
				best_dist = dist
			}
			dist = abs(frame - end)
			if dist <= m && (best == frame || dist < best_dist) {
				best = end
				best_dist = dist
			}
		}
	}
	return best
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

// asset_source_frames returns the total source frame count for a clip's asset,
// or -1 when unknown (no asset / generator clip). Used to cap lengthening so a
// clip never references past the end of its source media.
asset_source_frames :: proc(asset_id: u64) -> i64 {
	for &a in media_assets {
		if a.id == asset_id {
			return a.frame_count
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
// cap) grow freely until a neighbor. Returns the applied length.
resize_clip_right :: proc(track: ^Track, idx: int, new_tail: i64) -> i64 {
	c := &track.clips[idx]
	start := c.timeline_start_frame
	max_len := i64(1) << 50
	if src_total := asset_source_frames(c.asset_id); src_total > 0 {
		max_len = max(1, src_total - c.source_start_frame)
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
// frame, and never extends before the source (source_start_frame >= 0). Returns
// the applied length.
resize_clip_left :: proc(track: ^Track, idx: int, new_head: i64) -> i64 {
	c := &track.clips[idx]
	start := c.timeline_start_frame
	ssrc := c.source_start_frame
	end := start + c.source_length_frames
	// The head may extend left only as far as source frames precede the head.
	min_start := start - ssrc
	prev := clip_prev_end(track, idx)
	lo := max(min_start, prev)
	hi := end - 1
	if lo > hi {
		lo = hi
	}
	head := clamp(new_head, lo, hi)
	delta := head - start
	c.source_start_frame += delta
	c.timeline_start_frame = head
	c.source_length_frames = end - head
	return c.source_length_frames
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
	link := clip.link_id
	right_link := u64(0)
	if link != 0 {
		right_link = new_clip_id()
	}
	SplitTarget :: struct { track, index: int }
	targets := make([dynamic]SplitTarget, 0, 4)
	defer delete(targets)
	if link != 0 {
		for t := 0; t < len(timeline.tracks); t += 1 {
			for i := 0; i < len(timeline.tracks[t].clips); i += 1 {
				c := &timeline.tracks[t].clips[i]
				if c.link_id == link && frame >= c.timeline_start_frame && frame < clip_timeline_end(c^) {
					append(&targets, SplitTarget{t, i})
				}
			}
		}
	} else {
		append(&targets, SplitTarget{selected_track, selected_index})
	}
	if len(targets) == 0 {
		return
	}
	// Descending index order per track so injecting a right half never
	// invalidates a still-pending target's index on the same track.
	for t in 0 ..< len(targets) {
		for i := t + 1; i < len(targets); i += 1 {
			if targets[i].track > targets[t].track || (targets[i].track == targets[t].track && targets[i].index > targets[t].index) {
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
		right := c^
		// The new half is a distinct clip instance: re-mint its identity instead
		// of inheriting the left half's id (two clips sharing one clip_id breaks
		// every clip_id-keyed path -- preview slot identity, find_preview_slot,
		// the prewarm decoder handoff).
		right.clip_id = new_clip_id()
		right.link_id = right_link
		right.source_start_frame += left_len
		right.source_length_frames = right_len
		right.timeline_start_frame = frame
		old_markers := c.markers
		c.markers = filter_markers_in_range(old_markers[:], c.source_start_frame, left_len)
		c.source_length_frames = left_len
		right.markers = filter_markers_in_range(old_markers[:], right.source_start_frame, right_len)
		delete(old_markers)
		inject_at_elem(&tt.clips, target.index + 1, right)
	}
	if nered_trace {
		fmt.printf("[tl] split group link=%d (%d clips) @ %d\n", link, len(targets), frame)
	}
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
	clear(&drag_group_orig)
	audio_note_edit()
	if nered_trace {
		fmt.printf("[tl] unlinked %d clips (was link=%d)\n", count, link)
	}
}

// toggle_links_for_selection links or unlinks the current selection: the anchor
// clip plus every Shift+clicked clip in selected_set. A lone selection unlinks
// that clip's whole link group (video + audio become independent). With several
// clips the action toggles: if they already share one link_id every selected
// member is unlinked, otherwise they all join a fresh link group so later
// cuts/moves/deletes treat them as one unit.
toggle_links_for_selection :: proc() {
	_, anchor, ok := selected_clip()
	ids := make([dynamic]u64, 0, len(selected_set) + 1)
	defer delete(ids)
	if ok && anchor != nil {
		append(&ids, anchor.clip_id)
	}
	for id in selected_set {
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
	resolved := make([dynamic]^Clip, 0, len(ids))
	defer delete(resolved)
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
		if nered_trace {
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
	clear(&drag_group_orig)
	if same_group {
		for c in resolved {
			c.link_id = 0
		}
		audio_note_edit()
		if nered_trace {
			fmt.printf("[tl] unlinked %d selected clips\n", len(resolved))
		}
		return
	}
	new_link := new_clip_id()
	for c in resolved {
		c.link_id = new_link
	}
	audio_note_edit()
	if nered_trace {
		fmt.printf("[tl] linked %d selected clips (link=%d)\n", len(resolved), new_link)
	}
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

// delete_selected_clip_raw removes the selected clip (and, when it belongs to a
// link group, EVERY member of that group) from the timeline. No ripple, no
// region removal, no other clips/tracks affected: the timeline simply stops
// showing the clip(s) (a gap stays where they were). The group scope keeps a cut
// from leaving its video behind with no audio (or vice versa).
delete_selected_clip_raw :: proc() {
	if selected_track < 0 || selected_track >= len(timeline.tracks) {
		return
	}
	track := &timeline.tracks[selected_track]
	if selected_index < 0 || selected_index >= len(track.clips) {
		return
	}
	link := track.clips[selected_index].link_id
	Target :: struct { track, index: int }
	targets := make([dynamic]Target, 0, 4)
	defer delete(targets)
	if link != 0 {
		for t := 0; t < len(timeline.tracks); t += 1 {
			for i := 0; i < len(timeline.tracks[t].clips); i += 1 {
				if timeline.tracks[t].clips[i].link_id == link {
					append(&targets, Target{t, i})
				}
			}
		}
	} else {
		append(&targets, Target{selected_track, selected_index})
	}
	// Descending (track, index) so a removal on one track never invalidates a
	// still-pending target's index on the same track.
	for t in 0 ..< len(targets) {
		for i := t + 1; i < len(targets); i += 1 {
			if targets[i].track > targets[t].track || (targets[i].track == targets[t].track && targets[i].index > targets[t].index) {
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
		delete(removed.markers)
		if nered_trace {
			fmt.printf("[tl] deleted clip raw src=%s start=%d len=%d\n",
				removed.path, removed.timeline_start_frame, removed.source_length_frames)
		}
		removed_any = true
	}
	if !removed_any {
		return
	}
	if nered_trace {
		fmt.printf("[tl] deleted clip group link=%d (%d clips)\n", link, len(targets))
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

// ripple_delete_region removes the timeline region [start, start+length) from
// EVERY track at once (the "delete the clip area for all tracks" edit) and then
// closes the gap: clips fully after the region shift left by `length`, clips
// straddling the region edges get trimmed/split around it, and clips entirely
// inside it are dropped.
ripple_delete_region :: proc(start, length: i64) {
	if length <= 0 {
		return
	}
	for ti in 0 ..< len(timeline.tracks) {
		ripple_delete_track_region(ti, start, length)
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
		fmt.printf("[tl] ripple delete region [%d, %d)\n", start, start + length)
	}
	selected_track = -1
	selected_index = -1
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
	MemberSpan :: struct { track: int, start, length: i64 }
	spans := make([dynamic]MemberSpan, 0, 4)
	defer delete(spans)
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
	// Sort by (track asc, start DESC).
	for a in 0 ..< len(spans) {
		for b := a + 1; b < len(spans); b += 1 {
			later := spans[b].track < spans[a].track ||
				(spans[b].track == spans[a].track && spans[b].start > spans[a].start)
			if later {
				spans[a], spans[b] = spans[b], spans[a]
			}
		}
	}
	for s in spans {
		ripple_delete_track_region(s.track, s.start, s.length)
	}
	moving_clip = false
	moving_preview_clip = false
	drag_clip = nil
	drag_source_track = -1
	drag_source_index = -1
	drag_hover_track = -1
	invalidate_preview_slots()
	if nered_trace {
		fmt.printf("[tl] ripple delete linked group link=%d (%d members)\n", link, len(spans))
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

// is_clip_selected reports whether the clip at (track_idx, index) is part of the
// current selection: the anchor clip itself, or any member of the selected
// clip's link group. Highlighting every linked member makes a linked cut/move
// read as one unit instead of a lone border on the grabbed clip.
is_clip_selected :: proc(track_idx, index: int) -> bool {
	if track_idx == selected_track && index == selected_index {
		return true
	}
	if track_idx < 0 || track_idx >= len(timeline.tracks) || index < 0 || index >= len(timeline.tracks[track_idx].clips) {
		return false
	}
	candidate := &timeline.tracks[track_idx].clips[index]
	if candidate.clip_id in selected_set {
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
	    placed := clip_place_in_track(dst, -1, clip.source_length_frames, start)
	    ordered_remove(&src.clips, src_index)
	    append(&dst.clips, clip)
	    dst.clips[len(dst.clips)-1].timeline_start_frame = placed
	    // Keep dst sorted by start for stable rendering.
	    for i := len(dst.clips) - 1; i > 0 && dst.clips[i].timeline_start_frame < dst.clips[i-1].timeline_start_frame; i -= 1 {
		    dst.clips[i], dst.clips[i-1] = dst.clips[i-1], dst.clips[i]
	    }
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

// capture_link_group snapshots the original (track, start, length) of every clip
// sharing clip's link_id into drag_group_orig, anchor first. Non-linked clips
// leave the array empty (len 0 = single-clip edit; len 1 = linked clip that is
// its own whole group, e.g. single-lane media). Call at gesture start, before any
// mutation: the captured originals are the invariant the group delta is computed
// against on every following frame.
capture_link_group :: proc(clip: ^Clip, track: int) {
	clear(&drag_group_orig)
	if clip.link_id == 0 {
		return
	}
	append(&drag_group_orig, Drag_Group_Orig{clip_id = clip.clip_id, track = track, start = clip.timeline_start_frame, length = clip.source_length_frames})
	for t := 0; t < len(timeline.tracks); t += 1 {
		for i := 0; i < len(timeline.tracks[t].clips); i += 1 {
			c := &timeline.tracks[t].clips[i]
			if c.link_id == clip.link_id && c.clip_id != clip.clip_id {
				append(&drag_group_orig, Drag_Group_Orig{clip_id = c.clip_id, track = t, start = c.timeline_start_frame, length = c.source_length_frames})
			}
		}
	}
}

// apply_group_drag_to_members shifts every non-anchor member by the anchor's
// live drag delta (anchor_delta = new anchor start - original anchor start),
// each clamped to its own lane so no member overlaps a neighbor. Horizontal
// moves of a link group keep all members time-aligned with the anchor.
apply_group_drag_to_members :: proc(anchor_delta: i64) {
	if len(drag_group_orig) <= 1 {
		return
	}
	anchor_id := drag_group_orig[0].clip_id
	for m in drag_group_orig {
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
		clip := &track.clips[idx]
		gaps := clip_track_gaps(track, idx)
		gi := gap_for_start(gaps[:], m.start)
		if gi >= 0 {
			lo, hi := gaps[gi][0], gaps[gi][1] - m.length
			if hi < lo {
				hi = lo
			}
			clip.timeline_start_frame = clamp(m.start + anchor_delta, lo, hi)
		}
		delete(gaps)
	}
}

// group_delta_feasible reports whether every captured link-group member can
// land on its OWN lane at exactly m.start + delta (all moving together by
// delta, members vacating their originals simultaneously) without overlapping
// any NON-member clip. A group drag only ever advances to deltas that are
// feasible for every member: the anchor must never move into a slot a partner
// cannot reach.
group_delta_feasible :: proc(delta: i64) -> bool {
	if len(drag_group_orig) <= 1 {
		return true
	}
	members := make(map[u64]bool, len(drag_group_orig))
	defer delete(members)
	for m in drag_group_orig {
		members[m.clip_id] = true
	}
	for m in drag_group_orig {
		if m.track < 0 || m.track >= len(timeline.tracks) {
			return false
		}
		t := &timeline.tracks[m.track]
		ts := m.start + delta
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

// group_vertical_feasible reports whether every captured link-group member can
// land on dst lane = m.track + track_delta at the mouse-aligned position
// m.start + delta (clamped to >= 0) without overlapping a non-member clip there.
// This is the same rule group_delta_feasible applies horizontally, shifted to
// the destination lanes a vertical drop targets.
group_vertical_feasible :: proc(track_delta: int, delta: i64) -> bool {
	if len(drag_group_orig) == 0 {
		return false
	}
	members := make(map[u64]bool, len(drag_group_orig))
	defer delete(members)
	for m in drag_group_orig {
		members[m.clip_id] = true
	}
	for m in drag_group_orig {
		dst := m.track + track_delta
		if dst < 0 || dst >= len(timeline.tracks) {
			return false
		}
		ts := max(m.start + delta, 0)
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

// move_linked_group relocates every clip captured in drag_group_orig by
// track_delta tracks (the anchor's vertical drop), keeping each member
// laid-out at the same mouse-aligned horizontal offset the ghost showed:
// start = m.start + drag_group_delta. Refused (returns false, nothing moves)
// unless EVERY member can land at that exact spot on its destination lane
// without overlapping a non-member clip, then re-selects the anchor in its new
// home.
move_linked_group :: proc(track_delta: int) -> bool {
	if track_delta == 0 || len(drag_group_orig) == 0 {
		return false
	}
	if !group_vertical_feasible(track_delta, drag_group_delta) {
		return false
	}
	for m in drag_group_orig {
		dst := m.track + track_delta
		if dst < 0 || dst >= len(timeline.tracks) {
			return false
		}
	}
	PlannedMove :: struct { src_track, dst_track: int, start: i64, clip: Clip }
	planned := make([dynamic]PlannedMove, 0, len(drag_group_orig))
	defer delete(planned)
	for m in drag_group_orig {
		if m.track < 0 || m.track >= len(timeline.tracks) {
			return false
		}
		src := &timeline.tracks[m.track]
		idx := clip_index_by_id(src, m.clip_id)
		if idx < 0 {
			continue
		}
		clip := src.clips[idx]
		dst_track := m.track + track_delta
		if dst_track < 0 || dst_track >= len(timeline.tracks) {
			return false
		}
		// group_vertical_feasible already proved every member fits at the
		// mouse-aligned slot; commit exactly there (no per-member clamping,
		// which would silently split the group).
		start := max(m.start + drag_group_delta, 0)
		append(&planned, PlannedMove{src_track = m.track, dst_track = dst_track, start = start, clip = clip})
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
		for i := len(dst.clips) - 1; i > 0 && dst.clips[i].timeline_start_frame < dst.clips[i-1].timeline_start_frame; i -= 1 {
			dst.clips[i], dst.clips[i-1] = dst.clips[i-1], dst.clips[i]
		}
	}
	invalidate_preview_slots()
	audio_note_edit()
	// Re-select the anchor in its new home.
	for t := 0; t < len(timeline.tracks); t += 1 {
		for i := 0; i < len(timeline.tracks[t].clips); i += 1 {
			if timeline.tracks[t].clips[i].clip_id == drag_group_orig[0].clip_id {
				selected_track = t
				selected_index = i
			}
		}
	}
	return true
}

// resize_group_right resizes the whole link group's right edge to new_tail: the
// anchor clip is resized exactly as a single clip, then every other member's
// tail moves by the same delta, each clamped to its own lane/source. Returns the
// anchor's applied length. No-op for unlinked clips (drag_group_orig empty).
resize_group_right :: proc(track: ^Track, idx: int, new_tail: i64) -> i64 {
	applied := resize_clip_right(track, idx, new_tail)
	if len(drag_group_orig) == 0 || drag_group_orig[0].clip_id != track.clips[idx].clip_id {
		return applied
	}
	delta := applied - drag_group_orig[0].length
	for m in drag_group_orig {
		if m.clip_id == drag_group_orig[0].clip_id {
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
	if len(drag_group_orig) == 0 || drag_group_orig[0].clip_id != track.clips[idx].clip_id {
		return applied
	}
	delta := track.clips[idx].timeline_start_frame - drag_group_orig[0].start
	for m in drag_group_orig {
		if m.clip_id == drag_group_orig[0].clip_id {
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

// insert_track inserts a new empty track at the given index (0-based) in the
// timeline track list — e.g. between existing tracks.
insert_track :: proc(index: int) {
	track := Track{name = next_track_name()}
	inject_at_elem(&timeline.tracks, index, track)
}

// duplicate_track inserts a copy of the track directly ABOVE the original (at
// index, pushing the original down one row), deep-copying every clip into a new
// dynamic array so the two tracks are fully independent.
duplicate_track :: proc(index: int) {
	src := &timeline.tracks[index]
	new_track := Track{
		name = next_track_name(),
		layer = src.layer,
		clips = make([dynamic]Clip, 0, len(src.clips)),
	}
	// Copy each clip by VALUE: mutations below land on the duplicate, never on
	// the original track's clip. (A `for &c` loop would alias src.clips[i] and
	// sever the ORIGINAL's link group.)
	for i in 0 ..< len(src.clips) {
		c := src.clips[i]
		// A duplicated clip is an independent copy: sever its link group so
		// selecting it never drags the original's partner tracks along.
		c.link_id = 0
		if len(c.markers) > 0 {
			// Clone the markers array so the two tracks share no owned memory:
			// deleting one track (remove_track frees per-clip markers) must not
			// leave the other track's copy dangling.
			c.markers = filter_markers_in_range(c.markers[:], c.source_start_frame, c.source_length_frames)
		}
		append(&new_track.clips, c)
	}
	inject_at_elem(&timeline.tracks, index, new_track)
}

// duplicate_clip inserts an independent copy of the clip at (track_idx,index)
// on the same track, placed in the nearest free slot directly after the
// original, and returns the new clip's index. The copy is a fresh clip (new
// clip_id, link_id 0) with cloned name and markers, so the two never share
// state -- mirroring duplicate_track's copy-by-value semantics.
duplicate_clip :: proc(track_idx, index: int) -> int {
	track := &timeline.tracks[track_idx]
	src := &track.clips[index]
	c := Clip{
		clip_id                = new_clip_id(),
		asset_id               = src.asset_id,
		link_id                = 0,
		path                   = src.path,
		name                   = strings.clone(src.name),
		kind                   = src.kind,
		generator              = src.generator,
		srt_id                 = src.srt_id,
		stream_index           = src.stream_index,
		source_start_frame     = src.source_start_frame,
		source_length_frames   = src.source_length_frames,
		timeline_start_frame   = src.timeline_start_frame,
		layer                  = src.layer,
		source_w               = src.source_w,
		source_h               = src.source_h,
		transform_x            = src.transform_x,
		transform_y            = src.transform_y,
		scale                  = src.scale,
		crop_l                 = src.crop_l,
		crop_r                 = src.crop_r,
		crop_t                 = src.crop_t,
		crop_b                 = src.crop_b,
	}
	for m in src.markers {
		append(&c.markers, Clip_Marker{source_frame = m.source_frame, label = strings.clone(m.label)})
	}
	place := clip_timeline_end(src^)
	c.timeline_start_frame = clip_place_in_track(track, index, c.source_length_frames, place)
	insert_at := index + 1
	for insert_at < len(track.clips) && track.clips[insert_at].timeline_start_frame < c.timeline_start_frame {
		insert_at += 1
	}
	inject_at_elem(&track.clips, insert_at, c)
	return insert_at
}

// remove_track deletes the track at index (and all of its clips) from the
// timeline. Frees per-clip markers and the track's owned arrays, clears or
// adjusts the saved selection (clips on other tracks keep their indices, so
// selected_index is preserved), and invalidates the preview/audio state the
// way every clip-delete path must (see delete_selected_clip_raw).
remove_track :: proc(index: int) {
	if index < 0 || index >= len(timeline.tracks) {
		return
	}
	removed := timeline.tracks[index]
	for &c in removed.clips {
		delete(c.markers)
	}
	delete(removed.clips)
	delete(removed.name)
	ordered_remove(&timeline.tracks, index)
	switch {
	case selected_track == index:
		selected_track = -1
		selected_index = -1
	case selected_track > index:
		selected_track -= 1
	}
	moving_clip = false
	moving_preview_clip = false
	drag_clip = nil
	drag_source_track = -1
	drag_source_index = -1
	drag_hover_track = -1
	// CRITICAL: the removed clips' decoded frames/decoders/GPU textures must be
	// dropped or they keep painting at the playhead. Same rule as any delete.
	invalidate_preview_slots()
	audio_note_edit()
	return
}
