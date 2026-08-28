package main

import "core:fmt"
import "core:strconv"

// ---------------------------------------------------------------------------
// Timeline queries and structural edits: duration/ruler math, frame lookups,
// selection, and track insert/duplicate/naming.
// ---------------------------------------------------------------------------

clip_timeline_end :: proc(clip: Clip) -> i64 { return clip.timeline_start_frame + clip.source_length_frames }
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
	frame := playhead.frame
	for ti := 0; ti < len(timeline.tracks); ti += 1 {
		track := &timeline.tracks[ti]
		for i := 0; i < len(track.clips); i += 1 {
			clip := &track.clips[i]
			local := frame - clip.timeline_start_frame
			if local <= 0 || local >= clip.source_length_frames {
				continue
			}
			left_len := local
			right_len := clip.source_length_frames - local
			right := clip^
			clip.source_length_frames = left_len
			clip.markers = filter_markers_in_range(clip.markers[:], clip.source_start_frame, clip.source_length_frames)
			right.source_start_frame += local
			right.source_length_frames = right_len
			right.timeline_start_frame = frame
			right.markers = filter_markers_in_range(right.markers[:], right.source_start_frame, right.source_length_frames)
			inject_at_elem(&track.clips, i + 1, right)
			return
		}
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
