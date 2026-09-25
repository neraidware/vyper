package main

import "core:fmt"
import "core:mem"
import "core:sort"
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
	// mask: bit i set => this key packs lane i's value (a partial keyframe can
	// key any subset of a section's lanes — a fold knot only carries the lanes
	// with a breakpoint there). mask == 0 means a scalar key (value carries
	// .f32); mask != 0 means a section key (value carries a [KF_PACK_MAX]f32
	// indexed by LANE, meaningful where the mask bit is set).
	mask: u8,
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
// Sections: which scalar lane tracks group into one multi-lane animation.
//
// A section key (mask != 0) lives on a track named after the SECTION itself
// ("crop", "transform"); a scalar key lives on one LANE track ("crop.l").
// The section and its lanes are two migration forms of ONE animation and
// never coexist: keying a whole section folds any keyed lanes into packed
// form (kf_fold_lanes), keying an individual lane unwraps a packed section
// into per-lane tracks first (kf_unwrap_section). Both migrations are
// value-exact — same knots, same lane values, same interpolation: a packed
// knot only ever carries the lanes that have a breakpoint at that frame, so
// each lane's curve (and the section knot the fold sets) is its own.
//
// Lane ORDER here IS the packed lane index; the consumers read lanes through
// these SAME names (render_geom_name, preview_state's crop.l/r/t/b), so a
// packed key fans out to the right consumer field.
// ---------------------------------------------------------------------------
Kf_Section_Def :: struct {
	name:  string,
	lanes: []string,
}

kf_section_defs :: []Kf_Section_Def {
	{
		name  = "crop",
		lanes = []string{"crop.l", "crop.r", "crop.t", "crop.b"},
	},
	{
		name  = "transform",
		lanes = []string{"transform.x", "transform.y"},
	},
}

kf_section_index :: proc(name: string) -> (index: int, ok: bool) {
	defs := kf_section_defs
	for i in 0 ..< len(defs) {
		if defs[i].name == name {
			return i, true
		}
	}
	return 0, false
}

// kf_section_full_mask is the mask that keys every lane of section `sec` — the
// whole-group key shape. Names come from kf_section_defs verbatim, so an
// unknown name is an invariant error.
kf_section_full_mask :: proc(sec: string) -> u8 {
	sec_index, ok := kf_section_index(sec)
	assert(ok, "kf_section_full_mask: name is not a section")
	defs := kf_section_defs
	def := defs[sec_index]
	mask: u8 = 0
	for li in 0 ..< len(def.lanes) {
		mask |= 1 << uint(li)
	}
	return mask
}

// kf_section_for_lane maps a scalar LANE name to its (section index, lane
// index); a plain property (gain, scale) that groups with nothing misses.
kf_section_for_lane :: proc(name: string) -> (sec_index, lane_index: int, ok: bool) {
	defs := kf_section_defs
	for s in 0 ..< len(defs) {
		for li in 0 ..< len(defs[s].lanes) {
			if defs[s].lanes[li] == name {
				return s, li, true
			}
		}
	}
	return 0, 0, false
}

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
// frame without ever touching the live timeline. mask == 0 means "not keyed".
// The consumer that races the UI thread must memset-free nothing: dst is its
// own storage (a struct field), the copy is plain bytes.
// When `name` is a LANE of a section whose track lives in packed form, the
// section is unpacked here — each section key expands to a scalar key carrying
// `name`'s lane value (keys whose n don't cover the lane are skipped). The
// consumer's downstream reader (kf_sample_keys, render_kf_geom_rect) sees only
// scalars, so the worker seam stays packed-free.
kf_fill_snapshot :: proc(clip: ^Clip, name: string, dst: []Keyframe) -> (n, total: int) {
	sec_index, li, is_lane := kf_section_for_lane(name)
	if is_lane {
		defs := kf_section_defs
		sec := defs[sec_index].name
		si := kf_track_index(clip^, sec)
		if si >= 0 {
			assert(kf_track_index(clip^, name) < 0, "a lane must be absent while its section is packed")
			for k in clip.keyframe_tracks[si].keys {
				if _, covered := kf_lane_value(k, li); covered {
					total += 1
				}
			}
			n = min(total, len(dst))
			di := 0
			for k in clip.keyframe_tracks[si].keys {
				if v, covered := kf_lane_value(k, li); covered {
					if di < n {
						dst[di] = Keyframe {frame_off = k.frame_off, value = v}
						di += 1
					}
				}
			}
			return
		}
	}
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
	// A scalar key on a LANE of a section that is currently packed must make
	// the group give way FIRST: fan the section out to per-lane tracks, then
	// write. ("You keyed an individual value, so the array unwraps.")
	if sec_index, _, is_lane := kf_section_for_lane(name); is_lane {
		defs := kf_section_defs
		sec := defs[sec_index].name
		if kf_track_index(clip^, sec) >= 0 {
			kf_unwrap_section(clip, sec)
		}
	}
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

// --- packed sections: grouped keys for multi-lane properties -------------

// kf_set_packed_key records one section key on `sec`'s track at frame_off,
// replacing any key already on that frame — the packed twin of kf_set_key's
// insert. `lanes` is indexed by LANE, `mask` says which lanes this knot keys
// (only those entries are meaningful). Callers guarantee the section holds
// ONLY packed keys.
kf_set_packed_key :: proc(clip: ^Clip, sec: string, frame_off: i32, lanes: [KF_PACK_MAX]f32, mask: u8) {
	ti := kf_track_index(clip^, sec)
	if ti < 0 {
		append(&clip.keyframe_tracks, Kf_Track {name = strings.clone(sec)})
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

// kf_unwrap_section fans a packed section track out to per-lane scalar tracks
// — "you keyed an individual lane, so the group has to give way." Each packed
// key becomes one scalar key per lane its mask keys (on that lane's OWN track
// at the same frame), then the section track is dropped. Value-exact: the
// per-lane scalar animation reproduces the packed one knot-for-knot. Caller
// owns the structure bump. Paired invariant: a lane and its packed section
// never coexist.
kf_unwrap_section :: proc(clip: ^Clip, sec: string) {
	sec_index, ok := kf_section_index(sec)
	assert(ok, "kf_unwrap_section: name is not a section")
	si := kf_track_index(clip^, sec)
	if si < 0 {
		return
	}
	defs := kf_section_defs
	def := defs[sec_index]
	src_keys := clip.keyframe_tracks[si].keys
	for li in 0 ..< len(def.lanes) {
		assert(
			kf_track_index(clip^, def.lanes[li]) < 0,
			fmt.tprintf("lane %q coexists with its packed section %q", def.lanes[li], sec),
		)
		append(&clip.keyframe_tracks, Kf_Track {name = strings.clone(def.lanes[li])})
		lane := &clip.keyframe_tracks[len(clip.keyframe_tracks) - 1]
		lane.keys = make([dynamic]Keyframe, 0, len(src_keys))
		for k in src_keys {
			if v, covered := kf_lane_value(k, li); covered {
				append(&lane.keys, Keyframe {frame_off = k.frame_off, value = v})
			}
		}
	}
	// The section track is freed only after all fans read src_keys.
	name := clip.keyframe_tracks[si].name
	keys := clip.keyframe_tracks[si].keys
	delete(name)
	if keys != nil {
		delete(keys)
	}
	ordered_remove(&clip.keyframe_tracks, si)
}

// kf_any_lane_tracked reports whether any lane of `def` owns a live track.
kf_any_lane_tracked :: proc(clip: ^Clip, def: Kf_Section_Def) -> bool {
	for li in 0 ..< len(def.lanes) {
		if kf_track_index(clip^, def.lanes[li]) >= 0 {
			return true
		}
	}
	return false
}

// kf_fold_lanes migrates scalar lane tracks BACK to the packed section form —
// the reverse of kf_unwrap_section, run when a grouped key lands on top of
// keyed lanes. The union of every lane's key frames (plus the new set frame)
// becomes section knots; each knot keys ONLY the lanes that have a breakpoint
// there (their own key on that frame), and the set knot keys ALL lanes with
// the new group values. Because a lane never appears in a knot where it lacks
// its own breakpoint, its packed curve is exactly its scalar curve — the fold
// is value-exact: adding a whole-crop key over keyed lanes reproduces the
// per-lane animation everywhere the new key doesn't land, and unwrap (the
// reverse migration) lands back on the same per-lane tracks.
kf_fold_lanes :: proc(clip: ^Clip, sec_index: int, set_frame: i32, set_lanes: [KF_PACK_MAX]f32, full_mask: u8) {
	defs := kf_section_defs
	def := defs[sec_index]
	frames := make([dynamic]i32, 0, 8)
	defer delete(frames)
	for li in 0 ..< len(def.lanes) {
		if ti := kf_track_index(clip^, def.lanes[li]); ti >= 0 {
			assert(len(clip.keyframe_tracks[ti].keys) > 0, "an empty lane track is a store invariant violation")
			for k in clip.keyframe_tracks[ti].keys {
				append(&frames, k.frame_off)
			}
		}
	}
	append(&frames, set_frame)
	sort.quick_sort(frames[:])
	packed: [KF_PACK_MAX]f32
	for i := 0; i < len(frames); i += 1 {
		if i > 0 && frames[i] == frames[i-1] {
			continue // dedupe: one knot per unique frame
		}
		fk := frames[i]
		knot_mask: u8 = 0
		for li in 0 ..< len(def.lanes) {
			packed[li] = 0
			if fk == set_frame {
				packed[li] = set_lanes[li]
				knot_mask |= 1 << uint(li)
				continue
			}
			if ti := kf_track_index(clip^, def.lanes[li]); ti >= 0 {
				// A lane is in this knot only at its OWN key frames; a knot on
				// someone else's frame must not break its curve.
				for &ck in clip.keyframe_tracks[ti].keys {
					if ck.frame_off == fk {
						packed[li] = ck.value.(f32)
						knot_mask |= 1 << uint(li)
						break
					}
				}
			}
		}
		assert(knot_mask != 0, "a fold knot must key at least one lane")
		kf_set_packed_key(clip, def.name, fk, packed, knot_mask)
	}
	// The section now owns the animation; drop the lane tracks (which must
	// hold only keys — folding never leaves an authority behind).
	for li in 0 ..< len(def.lanes) {
		if ti := kf_track_index(clip^, def.lanes[li]); ti >= 0 {
			tr := &clip.keyframe_tracks[ti]
			assert(len(tr.keys) > 0, "folding dropped a keyed lane")
			delete(tr.name)
			delete(tr.keys)
			ordered_remove(&clip.keyframe_tracks, ti)
		}
	}
}

// kf_set_key_packed records a section key on `sec` at frame_off — the grouped
// producer (whole-crop / whole-transform keyframe). `lanes` is [lane]value,
// `mask` selects which lanes the key carries (a group key uses the section's
// full mask). Section and lanes are mutually exclusive forms: if any lane
// track already holds keys they are folded into the packed form first
// (kf_fold_lanes), then the key lands.
kf_set_key_packed :: proc(clip: ^Clip, sec: string, frame_off: i32, lanes: [KF_PACK_MAX]f32, mask: u8) {
	sec_index, ok := kf_section_index(sec)
	assert(ok, "kf_set_key_packed: name is not a section")
	defs := kf_section_defs
	def := defs[sec_index]
	full_mask := kf_section_full_mask(sec)
	assert(mask != 0 && mask & full_mask == mask, "kf_set_key_packed: mask keys lanes outside the section")
	kf_bump_structure()
	if kf_any_lane_tracked(clip, def) {
		kf_fold_lanes(clip, sec_index, frame_off, lanes, full_mask)
		return
	}
	kf_set_packed_key(clip, sec, frame_off, lanes, mask)
}

// kf_set_value edits ONE scalar's value at frame_off. On a packed section the
// section unwraps first and the edit lands on lane 0 (the readout's displayed
// lane) — the rule that any individual-value edit makes the group give way.
kf_set_value :: proc(clip: ^Clip, name: string, frame_off: i32, value: f32) {
	if sec_index, ok := kf_section_index(name); ok {
		if kf_track_index(clip^, name) < 0 {
			return
		}
		kf_unwrap_section(clip, name)
		defs := kf_section_defs
		kf_set_key(clip, defs[sec_index].lanes[0], frame_off, value)
		return
	}
	kf_set_key(clip, name, frame_off, value)
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

// kf_sample_packed_lane evaluates ONE lane `idx` over a packed section track
// (the packed twin of kf_sample, from the section track's own keys). A lane's
// curve is defined by the knots whose mask covers it: each such knot applies
// its lane value on its own frame, and between two adjacent covering knots the
// lane interpolates linearly toward the next covering knot's value. Knots that
// don't mask the lane are no breakpoint for it — the lane's curve runs
// straight through them, so a partial fold keeps every lane's own keyframe
// set intact. Before the lane's first covering knot and after its last, the
// lane is inactive and `base` rules.
kf_sample_packed_lane :: proc(track: ^Kf_Track, frame_off: i32, idx: int, base: f32) -> (f32, bool) {
	if track == nil || len(track.keys) == 0 {
		return base, false
	}
	prev_frame: i32
	prev_val: f32
	found := false
	for i := len(track.keys) - 1; i >= 0; i -= 1 {
		k := track.keys[i]
		if k.frame_off > frame_off {
			continue
		}
		if v, cov := kf_lane_value(k, idx); cov {
			if k.frame_off == frame_off {
				return v, true // the knot applies ITS value on its own frame
			}
			prev_frame = k.frame_off
			prev_val = v
			found = true
			break
		}
	}
	if !found {
		return base, false
	}
	for i := 0; i < len(track.keys); i += 1 {
		k := track.keys[i]
		if k.frame_off <= frame_off {
			continue
		}
		if nv, cov := kf_lane_value(k, idx); cov {
			span := k.frame_off - prev_frame
			t := f32(frame_off - prev_frame) / f32(span)
			return prev_val + (nv - prev_val) * t, true
		}
	}
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
// When `name` is a LANE of a section that lives in packed form, the packed
// section track is sampled for that lane instead of the (absent) lane track.
kf_sample_for :: proc(clip: ^Clip, name: string, timeline_frame: i64, base: f32) -> (f32, bool) {
	sec_index, li, is_lane := kf_section_for_lane(name)
	if is_lane {
		defs := kf_section_defs
		if si := kf_track_index(clip^, defs[sec_index].name); si >= 0 {
			assert(kf_track_index(clip^, name) < 0, "a lane must be absent while its section is packed")
			return kf_sample_packed_lane(
				&clip.keyframe_tracks[si],
				i32(timeline_frame - clip.timeline_start_frame),
				li,
				base,
			)
		}
	}
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
				// Preserve mask + union payload: a packed (section) key rides the
				// split/trim remap intact, mask=0 -> scalar comes along for free.
				append(&keys, Keyframe {frame_off = k.frame_off - lo, mask = k.mask, value = k.value})
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