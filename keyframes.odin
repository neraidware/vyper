package main

import "core:mem"
import "core:strings"

// ---------------------------------------------------------------------------
// Generic keyframe store (Active 3, S1).
//
// A keyframe track is an opaque, named (frame_off, value) series attached to a
// clip. The keyframing system NEVER interprets the track name: it matches,
// stores and samples it, and that is all. Whatever wants an animation (gain,
// transform, scale, a future property Clip does not even carry yet) mints a
// track named by its own property path and maps that name back to its field
// when wiring outputs -- the name->property mapping lives in the consumer, not
// here. The gutter label for a track IS its name. Godot-style.
//
// frame_off is clip-relative (timeline frame - clip.timeline_start_frame), so
// a track travels with its clip: drag and undo snapshots need zero remapping.
//
// Ownership: track names are cloned at creation and deep-cloned at every copy
// site (clone_timeline, duplicate_track/clip); split/trim remaps and
// free_timeline free what they replace. A clip that is merely carried along
// (drag, slide) keeps its track arrays shared, the marker-style convention.
// ---------------------------------------------------------------------------

// KF_MAX_OFFSET bounds "no upper limit" remap filters; 2^28 frames at 60fps is
// ~50 days, far past any real clip.
KF_MAX_OFFSET :: 268435456

// KF_PACK_MAX: widest packed key the store will hold. A section key fans its
// inner-scalar lanes into one Keyframe tuple; the widest real section is Crop
// (4 lanes: L/R/T/B) and Transform (2), so 7 leaves headroom without ever
// letting a consumer m,n grow past the fixed array that crosses the worker
// seam. Fixed array, never a slice -- a packed key rides the same raw byte
// copy (kf_sample_snapshot) the scalar path does, and a slice header would
// dangle there.
KF_PACK_MAX :: 7

Keyframe :: struct {
	// frame_off: clip-relative frame this key sits on. Sorted ascending.
	frame_off: i32,
	// n: number of packed lanes this key applies. n == 0 means a scalar key
	// (value carries .f32); n > 0 means a section key (value carries the
	// first n lanes of a [KF_PACK_MAX]f32) and the other lanes read as
	// inactive/resting -- the consumer unpacks section keys BEFORE sampling
	// so its per-scalar reader never sees a partial lane.
	n: u8,
	value: union {
		f32,
		[KF_PACK_MAX]f32,
	},
}

Kf_Track :: struct {
	// name: opaque id + gutter label. Consumer-defined; the store only matches.
	name: string,
	// keys: sorted ascending by frame_off.
	keys: [dynamic]Keyframe,
}

// --- lookups --------------------------------------------------------------

// kf_track_index returns the index of `name`'s track, or -1.
kf_track_index :: proc(clip: Clip, name: string) -> int {
	for i in 0 ..< len(clip.keyframe_tracks) {
		if clip.keyframe_tracks[i].name == name {
			return i
		}
	}
	return -1
}

// kf_fill_snapshot copies `name`'s track into `dst` (a flat fixed array) up to
// its cap, returning (copied, total). This is how a cross-thread consumer
// (audio producer, render worker) gets an OWN copy of a track it samples per
// frame without ever touching the live timeline. n == 0 means "not keyed".
// The consumer that races the UI thread must memset-free nothing: dst is its
// own storage (a struct field), the copy is plain bytes.
kf_fill_snapshot :: proc(clip: ^Clip, name: string, dst: []Keyframe) -> (n, total: int) {
	ti := kf_track_index(clip^, name)
	if ti < 0 {
		return 0, 0
	}
	tk := &clip.keyframe_tracks[ti]
	total = len(tk.keys)
	n = min(total, len(dst))
	if n > 0 {
		mem.copy(raw_data(dst[:n]), raw_data(tk.keys[:n]), n * size_of(Keyframe))
	}
	return
}

// --- discrete edits (undo-seam callers) -------------------------------------

// kf_set_key records `value` on `name`'s track at frame_off (clip-relative),
// replacing any key already on that frame. Creates the track on first key; a
// second property mints its own track. The name is cloned here so the live
// clip owns the string (free_timeline deletes track names; a literal would
// crash the delete).
// kf_bump_structure flags that a keyframe sequence has shifted, invalidating
// any live index-based selection (see kf_structure_gen). Wrap to skip 0 so a
// full-cycle wrap can't accidentally match a selection made at gen 0.
kf_bump_structure :: proc() {
	kf_structure_gen += 1
	if kf_structure_gen == 0 {
		kf_structure_gen = 1
	}
}

kf_set_key :: proc(clip: ^Clip, name: string, frame_off: i32, value: f32) {
	kf_bump_structure()
	ti := kf_track_index(clip^, name)
	if ti < 0 {
		append(&clip.keyframe_tracks, Kf_Track {name = strings.clone(name)})
		ti = len(clip.keyframe_tracks) - 1
	}
	track := &clip.keyframe_tracks[ti]
	// Insertion point: last key at-or-before frame_off.
	ip := 0
	for ip < len(track.keys) && track.keys[ip].frame_off <= frame_off {
		ip += 1
	}
	if ip > 0 && track.keys[ip-1].frame_off == frame_off {
		track.keys[ip-1].value = value
		return
	}
	// Grow the dynamic array by one (sentinel slot) before the slide, so both
	// the fresh-track first key (ip == 0, empty keys) and an end-append
	// (ip == len(old keys)) have a valid slot to land in.
	append(&track.keys, Keyframe {})
	if ip < len(track.keys) - 1 {
		// Slide the tail right to make room, keeping the array sorted.
		mem.copy(
			mem.raw_data(track.keys[ip + 1:]),
			mem.raw_data(track.keys[ip:len(track.keys) - 1]),
			size_of(Keyframe) * (len(track.keys) - 1 - ip),
		)
	}
	track.keys[ip] = Keyframe {frame_off = frame_off, value = value}
}

// kf_del_key removes the key at frame_off from `name`'s track; drops the track
// once it empties (a track exists <=> it holds a key).
kf_del_key :: proc(clip: ^Clip, name: string, frame_off: i32) {
	kf_bump_structure()
	ti := kf_track_index(clip^, name)
	if ti < 0 {
		return
	}
	track := &clip.keyframe_tracks[ti]
	for i in 0 ..< len(track.keys) {
		if track.keys[i].frame_off == frame_off {
			if i < len(track.keys) - 1 {
				mem.copy(
					mem.raw_data(track.keys[i:]),
					mem.raw_data(track.keys[i + 1:]),
					size_of(Keyframe) * (len(track.keys) - 1 - i),
				)
			}
			pop(&track.keys)
			break
		}
	}
	if len(track.keys) == 0 {
		delete(track.name)
		track.name = ""
		ordered_remove(&clip.keyframe_tracks, ti)
	}
}

// --- evaluation (linear between keys, base outside them) ----------------

// kf_sample_keys is the keyed evaluation over a flat key slice — the same
// algorithm kf_sample runs over a track, exposed separately so the audio
// producer can sample a SNAPSHOT of a clip's gain track it owns (it may never
// touch the live timeline). A key applies ITS value on its own frame; between
// two adjacent keys the value interpolates linearly so it reaches the NEXT
// key's value exactly on that key's frame. Before the first key and after the
// last key the property is INACTIVE: the caller keeps its own (base/resting)
// value, so direct edits and drags apply there.
kf_sample_keys :: proc(keys: []Keyframe, frame_off: i32, base: f32) -> (f32, bool) {
	if len(keys) == 0 {
		return base, false
	}
	active := len(keys) - 1
	for active >= 0 && keys[active].frame_off > frame_off {
		active -= 1
	}
	if active < 0 {
		return base, false
	}
	active_key := keys[active]
	if frame_off == active_key.frame_off {
		return active_key.value.(f32), true
	}
	// A later key starts a segment from this key's frame; interpolate toward
	// it so the next key's value lands exactly on its own frame.
	if active + 1 < len(keys) {
		next_key := keys[active + 1]
		span := next_key.frame_off - active_key.frame_off
		t := f32(frame_off - active_key.frame_off) / f32(span)
		return active_key.value.(f32) + (next_key.value.(f32) - active_key.value.(f32)) * t, true
	}
	// Past the last key the property is under direct control again.
	return base, false
}

// kf_sample evaluates the keyed value for clip-relative frame_off.
//
// A key applies ITS value on its own frame (creating or editing a keyframe is
// visible immediately); between two adjacent keys the value interpolates
// linearly and arrives at the NEXT key's value exactly on that key's frame.
// Before the first key and after the last key the property is inactive and
// the caller keeps its own value — direct edits and drags apply there.
kf_sample :: proc(track: ^Kf_Track, frame_off: i32, base: f32) -> (f32, bool) {
	if track == nil || len(track.keys) == 0 {
		return base, false
	}
	return kf_sample_keys(track.keys[:], frame_off, base)
}

// kf_sample_for resolves `name` against the clip and samples at a TIMELINE
// frame, relative to the clip start -- the caller-facing generic entry point.
kf_sample_for :: proc(clip: ^Clip, name: string, timeline_frame: i64, base: f32) -> (f32, bool) {
	ti := kf_track_index(clip^, name)
	if ti < 0 {
		return base, false
	}
	return kf_sample(&clip.keyframe_tracks[ti], i32(timeline_frame - clip.timeline_start_frame), base)
}

// --- deep-copy / free (the clip ownership matrix's keyframe half) -----------

// kf_clone_mut deep-clones src's tracks into dst, REPLACING dst's current
// tracks. Callers are the deep-copy sites (clone_timeline snapshots,
// duplicate_track/clip): after this the two clips share no owned memory. dst's
// prior tracks are NOT freed -- callers hand a fresh struct (or one whose
// tracks alias src, like the split copies), so freeing would hit src's memory.
kf_clone_mut :: proc(dst: ^Clip, src: Clip) {
	if len(src.keyframe_tracks) == 0 {
		dst.keyframe_tracks = nil
		return
	}
	dst.keyframe_tracks = make([dynamic]Kf_Track, len(src.keyframe_tracks))
	for i in 0 ..< len(src.keyframe_tracks) {
		st := src.keyframe_tracks[i]
		nt := Kf_Track {name = strings.clone(st.name)}
		if len(st.keys) > 0 {
			nt.keys = make([dynamic]Keyframe, len(st.keys))
			copy(nt.keys[:], st.keys[:])
		}
		dst.keyframe_tracks[i] = nt
	}
}

// kf_free_tracks releases one clip's keyframe data: each track's name string
// and keys backing, then the tracks array itself. Call only on arrays the clip
// solely owns (teardown, delete paths).
kf_free_tracks :: proc(tracks: [dynamic]Kf_Track) {
	for &t in tracks {
		if t.name != "" {
			delete(t.name)
		}
		if t.keys != nil {
			delete(t.keys)
		}
	}
	delete(tracks)
}

// kf_rebuild_tracks builds a fresh track array from src by filtering each
// track's keys to clip-relative [lo, hi), re-relativizing survivors by -lo and
// cloning the track name. Tracks left with no keys are dropped. src is
// untouched (its owner frees it after the halves are built), so the output
// shares no owned memory with it.
kf_rebuild_tracks :: proc(src: [dynamic]Kf_Track, lo, hi: i32) -> [dynamic]Kf_Track {
	out := make([dynamic]Kf_Track, 0, len(src))
	for st in src {
		keys := make([dynamic]Keyframe, 0, len(st.keys))
		for k in st.keys {
			if k.frame_off >= lo && k.frame_off < hi {
				append(&keys, Keyframe {frame_off = k.frame_off - lo, value = k.value})
			}
		}
		if len(keys) > 0 {
			append(&out, Kf_Track {name = strings.clone(st.name), keys = keys})
		} else {
			delete(keys)
		}
	}
	return out
}

// kf_split_parts remaps one clip's tracks across a clip split into two halves
// at the clip-relative boundary `cut` (== the left half's new length). LEFT
// keeps keys < cut untouched; RIGHT keeps keys >= cut, re-relativized by -cut;
// values preserved (the slice-1 split rule). The source backing both halves
// alias is freed; each half owns fresh clones.
kf_split_parts :: proc(left, right: ^Clip, cut: i32) {
	if len(left.keyframe_tracks) == 0 {
		return
	}
	kf_bump_structure()
	old := left.keyframe_tracks
	left.keyframe_tracks = kf_rebuild_tracks(old, 0, cut)
	right.keyframe_tracks = kf_rebuild_tracks(old, cut, KF_MAX_OFFSET)
	kf_free_tracks(old)
}

// kf_trim_head drops keys on the trimmed head and re-relativizes the rest
// (a clip whose head was cut off and which shifted left by `cut`).
kf_trim_head :: proc(clip: ^Clip, cut: i32) {
	if len(clip.keyframe_tracks) == 0 {
		return
	}
	kf_bump_structure()
	old := clip.keyframe_tracks
	clip.keyframe_tracks = kf_rebuild_tracks(old, cut, KF_MAX_OFFSET)
	kf_free_tracks(old)
}

// kf_trim_tail drops keys beyond the clip's new length (`keep` = new length);
// survivors keep their offsets.
kf_trim_tail :: proc(clip: ^Clip, keep: i32) {
	if len(clip.keyframe_tracks) == 0 {
		return
	}
	kf_bump_structure()
	old := clip.keyframe_tracks
	clip.keyframe_tracks = kf_rebuild_tracks(old, 0, keep)
	kf_free_tracks(old)
}

// kf_rows_for is how many keyframe lanes a track's row shows: the most keyframe
// tracks any single clip in the track carries, so the row is tall enough for
// the tallest clip. Clips with fewer tracks leave their own lanes shorter (the
// wrap is only as tall as it needs) and top-align with the rest of the row.
kf_rows_for :: proc(track: ^Track) -> int {
	rows := 0
	for &c in track.clips {
		if len(c.keyframe_tracks) > rows {
			rows = len(c.keyframe_tracks)
		}
	}
	return rows
}