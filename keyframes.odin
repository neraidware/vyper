package main

import "core:math"
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

// KF_PACK_MAX: the widest packed key the store will hold — a consumer's
// grouped tracks may not exceed it, and it is a FORMAT constant: Keyframe's
// payload is this fixed array, so changing it changes every stored key. Fixed
// array, never a slice -- a packed key rides the same raw byte copy
// (kf_fill_snapshot) the scalar path does, and a slice header would dangle
// there.
KF_PACK_MAX :: 7

// Kf_Interp is the easing a key applies to the segment ARRIVING at it from the
// previous key — we ease INTO a breakpoint, so the key you're heading to owns
// the curve. .Cubic is the zero value — a fresh key defaults to the spline
// (cubic Hermite over neighbor-estimated tangents); .Linear and the rest are
// closed-form curves evaluated in kf_ease. Samplers use kf_apply_interp so
// scalar and packed lanes share one curve. The very first key has nothing
// arriving at it, so its mode is inert.
Kf_Interp :: enum u8 {
	Cubic,
	Linear,
	Ease_In,
	Ease_Out,
	Ease_In_Out,
	Elastic,
}

// Elastic is the Penner easeOutElastic over one segment: an amplitude envelope
// 2^(-ELASTIC_DECAY·t) over ELASTIC_FREQ_CYCLES sine cycles, re-centred to land
// (+ a hair past) the next key's value at t=1. It overshoots on purpose — that
// is the bounce the name promises, so sampled values may leave [l, r].
ELASTIC_DECAY :: 10 // 2^(-10·t): drops to ~1/1000 of its start by t=1.
ELASTIC_FREQ_CYCLES :: 3 // complete sine swings per segment.
// ELASTIC_PHASE shifts the sine so t=0 opens at the trough (sin(-π/2) ≈ -1):
// value stays 0 at the key, then bounces forward of the target.
ELASTIC_PHASE :: 0.75

Keyframe :: struct {
	// frame_off: clip-relative frame this key sits on. Sorted ascending.
	frame_off: i32,
	// mask: bit i set => this key packs lane i's value (a partial keyframe can
	// key any subset of a packed group's lanes — a consumer's migration knot
	// only carries the lanes with a breakpoint there). mask == 0 means a scalar
	// key (value carries .f32); mask != 0 means a packed key (value carries a
	// [KF_PACK_MAX]f32 indexed by LANE, meaningful where the mask bit is set).
	mask: u8,
	// interp: easing for the segment arriving at this key from the previous
	// one. Scalar and packed keys both carry it; a packed knot's mode applies
	// to every lane it covers.
	interp: Kf_Interp,
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

// ---------------------------------------------------------------------------
// Packed keys: a track whose keys carry a [KF_PACK_MAX]f32 payload instead of
// a scalar, with a mask saying which lanes each knot keys. A consumer groups
// named scalar tracks into one packed track and owns every naming decision
// (which properties group, what a lane is called, when the two forms migrate);
// the store only reads and writes the packed form. A lane's packed index is its
// position within the consumer's group, so a packed key fans out to the right
// consumer field.
// ---------------------------------------------------------------------------
// kf_lane_value reads lane `idx` of a packed key: the value when the key's
// mask covers idx, otherwise the "this knot leaves the lane alone" answer —
// a lane with no bit here has no breakpoint at this knot, so its curve runs
// through the knot untouched.
kf_lane_value :: proc(k: Keyframe, idx: int) -> (value: f32, covered: bool) {
	if k.mask == 0 || (k.mask >> uint(idx)) & 1 == 0 {
		return 0, false
	}
	switch v in k.value {
	case [KF_PACK_MAX]f32:
		return v[idx], true
	case f32:
	}
	assert(false, "a key with a nonzero mask must carry the [KF_PACK_MAX]f32 union variant")
	return 0, false
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
// frame without ever touching the live timeline. The consumer that races the
// UI thread must memset-free nothing: dst is its own storage (a struct field),
// the copy is plain bytes. A consumer whose track may live in PACKED form
// snapshots through its own lane-aware entry point (kf_geom_fill_snapshot), so
// the worker seam stays packed-free.
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
// crash the delete). Writes a SCALAR key on `name`'s own track; a consumer that
// groups names into packed tracks unwraps first (kf_geom_set_lane_key).
// kf_bump_structure flags that a keyframe sequence has shifted, invalidating
// any live index-based selection (see kf_view.structure_gen). Wrap to skip 0 so a
// full-cycle wrap can't accidentally match a selection made at gen 0.
kf_bump_structure :: proc() {
	kf_view.structure_gen += 1
	if kf_view.structure_gen == 0 {
		kf_view.structure_gen = 1
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

// --- packed writes ---------------------------------------------------------

// kf_set_packed_key records one packed key on `name`'s track at frame_off,
// replacing any key already on that frame — the packed twin of kf_set_key's
// insert. `lanes` is indexed by LANE, `mask` says which lanes this knot keys
// (only those entries are meaningful). `name` is just the consumer-chosen track
// name; the store does not know or care that it names a group.
kf_set_packed_key :: proc(clip: ^Clip, name: string, frame_off: i32, lanes: [KF_PACK_MAX]f32, mask: u8) {
	ti := kf_track_index(clip^, name)
	if ti < 0 {
		append(&clip.keyframe_tracks, Kf_Track {name = strings.clone(name)})
		ti = len(clip.keyframe_tracks) - 1
	}
	track := &clip.keyframe_tracks[ti]
	ip := 0
	for ip < len(track.keys) && track.keys[ip].frame_off <= frame_off {
		ip += 1
	}
	if ip > 0 && track.keys[ip-1].frame_off == frame_off {
		track.keys[ip-1].mask = mask
		track.keys[ip-1].value = lanes
		return
	}
	// Grow the dynamic array by one (sentinel slot) before the slide, the
	// same first-key/end-append/ordered-insert contract kf_set_key uses.
	append(&track.keys, Keyframe {})
	if ip < len(track.keys) - 1 {
		mem.copy(
			mem.raw_data(track.keys[ip + 1:]),
			mem.raw_data(track.keys[ip:len(track.keys) - 1]),
			size_of(Keyframe) * (len(track.keys) - 1 - ip),
		)
	}
	track.keys[ip] = Keyframe {frame_off = frame_off, mask = mask, value = lanes}
}

// --- curve math (easing + spline evaluators) -----------------------------

// kf_ease maps normalized segment time t∈[0,1] for the closed-form easing
// modes (.Cubic is a spline and is never routed here — kf_apply_interp
// resolves it). Elastic may push past [0,1]: that overshoot is the point.
kf_ease :: proc(interp: Kf_Interp, t: f32) -> f32 {
	switch interp {
	case .Cubic:
		// Hermite basis handles spline segments in kf_apply_interp.
		return t
	case .Linear:
		return t
	case .Ease_In:
		return t * t * t
	case .Ease_Out:
		u := 1 - t
		return 1 - u * u * u
	case .Ease_In_Out:
		if t < 0.5 {
			return 4 * t * t * t
		}
		u := -2 * t + 2
		return 1 - u * u * u / 2
	case .Elastic:
		if t == 0 {
			return 0
		}
		if t == 1 {
			return 1
		}
		return (
			math.pow(2, -ELASTIC_DECAY * t) *
			math.sin((t * ELASTIC_DECAY - ELASTIC_PHASE) * ((2 * math.PI) / f32(ELASTIC_FREQ_CYCLES))) +
			1
		)
	}
	return t
}

// kf_chord_slope is the per-frame value slope of the straight line `a`→`b`
// (value/frame). It is the natural end condition for the spline: a missing
// neighbor defaults the tangent to the chord slope, which reduces cubic Hermite
// to plain linear interpolation on that end.
kf_chord_slope :: proc(a, b: Keyframe) -> f32 {
	return (b.value.(f32) - a.value.(f32)) / f32(b.frame_off - a.frame_off)
}

// kf_apply_interp evaluates one segment at normalized t∈[0,1], shaped by the
// arriving key's mode (the segment between l and r ends at r, so r owns the
// curve — the mode the keyframe readout selects). For .Cubic, m0/m1 are the
// per-frame tangent slopes at the endpoints, estimated by the caller from the
// neighbor keys and scaled to the segment by `span`; the Hermite basis then
// interpolates l→r with those tangents. Every other mode is l + (r−l)·kf_ease.
// `span` is in frames and always > 0 (adjacent keys are strictly sorted and
// distinct).
kf_apply_interp :: proc(l, r: f32, t: f32, interp: Kf_Interp, m0, m1: f32, span: f32) -> f32 {
	assert(span > 0)
	switch interp {
	case .Cubic:
		t2 := t * t
		t3 := t2 * t
		h00 := 2 * t3 - 3 * t2 + 1
		h10 := t3 - 2 * t2 + t
		h01 := -(2 * t3) + 3 * t2
		h11 := t3 - t2
		return h00 * l + h10 * (m0 * span) + h01 * r + h11 * (m1 * span)
	case .Linear, .Ease_In, .Ease_Out, .Ease_In_Out, .Elastic:
		return l + (r - l) * kf_ease(interp, t)
	}
	return l
}

// --- evaluation (interpolated between keys, base outside them) -----------

// kf_sample_keys is the keyed evaluation over a flat key slice — the same
// algorithm kf_sample runs over a track, exposed separately so the audio
// producer re-evaluates keyed gain from its own snapshot (kf_fill_snapshot)
// without touching the live timeline. A key applies ITS value on its own
// frame; between two adjacent keys the value follows the NEXT key's
// interpolation mode (we ease INTO it) so it reaches that key's value exactly
// on its own frame. Before the first key and after the last key the property
// is INACTIVE:
// the caller keeps its own (base/resting) value, so direct edits and drags
// apply there.
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
	// A later key starts a segment from this key's frame; the ARRIVING key's
	// mode shapes the curve into it, and the next key's value still lands
	// exactly on its own frame.
	if active + 1 < len(keys) {
		next_key := keys[active + 1]
		span := f32(next_key.frame_off - active_key.frame_off)
		t := f32(frame_off - active_key.frame_off) / span
		// Spline tangents (value/frame) at each endpoint, estimated from the
		// outside neighbor keys. A missing neighbor defaults to the chord slope
		// (linear at that end — natural edge condition).
		m0 := kf_chord_slope(active_key, next_key)
		if active >= 1 {
			prev_key := keys[active - 1]
			m0 = (next_key.value.(f32) - prev_key.value.(f32)) / f32(next_key.frame_off - prev_key.frame_off)
		}
		m1 := kf_chord_slope(active_key, next_key)
		if active + 2 < len(keys) {
			later_key := keys[active + 2]
			m1 = (later_key.value.(f32) - active_key.value.(f32)) / f32(later_key.frame_off - active_key.frame_off)
		}
		return kf_apply_interp(active_key.value.(f32), next_key.value.(f32), t, next_key.interp, m0, m1, span), true
	}
	// Past the last key the property is under direct control again.
	return base, false
}

// kf_sample_packed_lane evaluates ONE lane `idx` over a packed section track
// (the packed twin of kf_sample, from the section track's own keys). A lane's
// curve is defined by the knots whose mask covers it: each such knot applies
// its lane value on its own frame, and between two adjacent covering knots the
// lane arrives following the NEXT covering knot's interpolation mode (easing
// into it, like the scalar path). Knots that don't mask the lane are no
// breakpoint for it — the lane's curve runs straight through them, so a partial
// fold keeps every lane's own keyframe set intact. Before the lane's first
// covering knot and after its last, the lane is inactive and `base` rules.
kf_sample_packed_lane :: proc(track: ^Kf_Track, frame_off: i32, idx: int, base: f32) -> (f32, bool) {
	if track == nil || len(track.keys) == 0 {
		return base, false
	}
	// Backward scan: the last covering knot at or before the frame (prev) and
	// the covering knot before it (prev2), which anchors the spline's left
	// tangent when it exists.
	prev: Keyframe
	prev2: Keyframe
	have_prev := false
	have_prev2 := false
	for i := len(track.keys) - 1; i >= 0; i -= 1 {
		k := track.keys[i]
		if k.frame_off > frame_off {
			continue
		}
		if _, covered := kf_lane_value(k, idx); covered {
			if have_prev {
				prev2 = k
				have_prev2 = true
				break
			}
			prev = k
			have_prev = true
		}
	}
	if !have_prev {
		return base, false
	}
	if v, _ := kf_lane_value(prev, idx); prev.frame_off == frame_off {
		return v, true // the knot applies ITS value on its own frame
	}
	// Forward scan: the first covering knot after the frame (next) and the one
	// after it (next2) for the spline's right tangent.
	next: Keyframe
	next2: Keyframe
	have_next := false
	have_next2 := false
	for i := 0; i < len(track.keys); i += 1 {
		k := track.keys[i]
		if k.frame_off <= frame_off {
			continue
		}
		if _, covered := kf_lane_value(k, idx); covered {
			if have_next {
				next2 = k
				have_next2 = true
				break
			}
			next = k
			have_next = true
		}
	}
	if !have_next {
		return base, false
	}
	span := f32(next.frame_off - prev.frame_off)
	t := f32(frame_off - prev.frame_off) / span
	lv, _ := kf_lane_value(prev, idx)
	rv, _ := kf_lane_value(next, idx)
	// The segment's mode is next's (the knot the segment eases INTO — we arrive
	// at it, so it owns the curve). Tangent slopes default to the chord when a
	// covering neighbor is missing, so partial folds and track edges stay
	// linear.
	m0 := (rv - lv) / span
	if have_prev2 {
		p2v, _ := kf_lane_value(prev2, idx)
		m0 = (rv - p2v) / f32(next.frame_off - prev2.frame_off)
	}
	m1 := (rv - lv) / span
	if have_next2 {
		n2v, _ := kf_lane_value(next2, idx)
		m1 = (n2v - lv) / f32(next2.frame_off - prev.frame_off)
	}
	return kf_apply_interp(lv, rv, t, next.interp, m0, m1, span), true
}

// kf_sample evaluates the keyed value for clip-relative frame_off.
//
// A key applies ITS value on its own frame (creating or editing a keyframe is
// visible immediately); between two adjacent keys the value follows the NEXT
// key's interpolation mode (we ease INTO it) and arrives at that key's value
// exactly on its own frame. Before the first key and after the last key the
// property is inactive and the caller keeps its own value — direct edits and
// drags apply there.
kf_sample :: proc(track: ^Kf_Track, frame_off: i32, base: f32) -> (f32, bool) {
	if track == nil || len(track.keys) == 0 {
		return base, false
	}
	return kf_sample_keys(track.keys[:], frame_off, base)
}

// kf_sample_for resolves `name` against the clip and samples at a TIMELINE
// frame, relative to the clip start -- the caller-facing generic entry point.
// A consumer whose `name` may live inside a PACKED track samples through its
// own lane-aware entry point (kf_geom_sample_lane).
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
// Preserve mask + union payload + interpolation mode: a packed
			// (section) key rides the split/trim remap intact with its own
			// curve, mask=0 -> scalar comes along for free. Dropping interp
			// here (as each half is a NEW key) would silently reset every
			// eased/spline mode to Linear on split or trim.
			append(&keys, Keyframe {frame_off = k.frame_off - lo, mask = k.mask, value = k.value, interp = k.interp})
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