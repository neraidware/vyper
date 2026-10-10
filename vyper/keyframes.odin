package vyper

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
// Ownership: lane NAMES are session-pool handles (TODO.md Active 19) -- interned
// once, owned by the session, copied by a struct copy, never freed per track.
// Key ARRAYS are still owned per track at this step: deep-copied at every copy
// site (clone_timeline, duplicate_track/clip) and freed by split/trim remaps and
// free_timeline. A clip that is merely carried along (drag, slide) keeps its
// track arrays shared, the marker-style convention.
// ---------------------------------------------------------------------------

// KF_MAX_OFFSET bounds "no upper limit" remap filters; 2^28 frames at 60fps is
// ~50 days, far past any real clip.
KF_MAX_OFFSET :: 268435456


// Keyframe_Interp is the easing a key applies to the segment ARRIVING at it from the
// previous key — we ease INTO a breakpoint, so the key you're heading to owns
// the curve. .Cubic is the zero value — a fresh key defaults to the spline
// (cubic Hermite over neighbor-estimated tangents); .Linear and the rest are
// closed-form curves evaluated in keyframe_ease. Samplers use keyframe_apply_interp so
// scalar and packed lanes share one curve. The very first key has nothing
// arriving at it, so its mode is inert.
Keyframe_Interp :: enum u8 {
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

// Keyframe is ONE scalar key on ONE lane. There is no packed form: a key's
// value is a plain f32 and the lane it belongs to is carried by WHICH lane's key
// window holds it, not by a runtime tag inside the key.
//
// The scalar/packed union this replaced (TODO.md Active 52) was the source of a
// whole class of bug: whether a knot was scalar or packed lived in `mask != 0`,
// decided at the CALL SITE, so a scalar sampler that met a packed knot asserted
// and aborted the process, and one animation had two storage forms with
// value-exact migrations keeping them in sync. A group of N lanes is now N scalar
// key windows; keying the group writes each lane; "which lanes are keyed on this
// frame" is a derived question, never a stored fact.
Keyframe :: struct {
	// frame_off: clip-relative frame this key sits on. Sorted ascending.
	frame_off: i32,
	// interp: easing for the segment arriving at this key from the previous one.
	interp: Keyframe_Interp,
	value:  f32,
}

// Keyframe_Lane is ONE scalar property's key curve inside a track. A group is just
// several lanes: crop has four (l/r/t/b), transform has two (x/y), gain has one.
// Each lane is an independent sorted key window into the session key arena, so a
// track copy is a struct copy and lane sharing/COW keeps working exactly as it
// did when the whole track shared one window.
Keyframe_Lane :: struct {
	// keys: sorted ascending by frame_off. A window into the session key store
	// (session_kf.odin), not an owned array: the session owns the slots and
	// outlives every holder. Read through session_kf_view/session_kf_at, mutate
	// through session_kf_push/insert/erase/set after session_kf_make_unique has
	// resolved sharing (TODO.md Active 19, S2b).
	keys: Keyframe_Keys_Range,
}

Keyframe_Track :: struct {
	// name: opaque id + gutter label. Consumer-defined; the store only matches.
	// A session-pool handle (TODO.md Active 19): the bytes are immutable and
	// owned by the session, so a track copy is a struct copy. Read through
	// keyframe_track_name, match through keyframe_track_index.
	name: Session_Str_Handle,
	// lanes: this track's scalar key curves. Empty for a static property (no
	// keys anywhere), one for a plain keyed property (gain), N for a keyed
	// group (transform.x/.y, crop.l/.r/.t/.b).
	lanes: [dynamic]Keyframe_Lane,
}

// keyframe_track_name is the track's name. The result borrows the pool. Note this is
// the KEYFRAME lane name, not a timeline Track's name -- both are called `name`
// and both are plain strings, so read the right one at each site.
keyframe_track_name :: proc(t: ^Keyframe_Track) -> string {
	return session_str_view(t.name)
}

// --- lanes ------------------------------------------------------------------
//
// A track is a set of scalar LANES, one per keyed property it owns. The arity is
// len(track.lanes): a plain keyed property (gain) has one, a group (transform.x
// / .y, or crop.l/.r/.t/.b) has several. This replaced a [KF_PACK_MAX]f32 payload
// plus a runtime `mask` tag (TODO.md Active 52); arity is now structural, so the
// scalar/packed class of bug is gone rather than merely guarded.

// keyframe_lane_count is how many scalar key curves a track carries.
keyframe_lane_count :: proc(t: ^Keyframe_Track) -> int {
	return len(t.lanes)
}

// keyframe_lane_view is lane `i`'s keys, read-only. Returns an empty range when the
// track has no such lane, so a caller iterating a group never has to bounds
// check against a count it derived elsewhere.
keyframe_lane_view :: proc(t: ^Keyframe_Track, i: int) -> Keyframe_Keys_Range {
	if i < 0 || i >= len(t.lanes) {
		return {}
	}
	return t.lanes[i].keys
}

// keyframe_lane_key reads one key by (track, lane, key index). It is the read side of
// keyframe_key_mut, and exists so a caller -- a probe asserting on stored state, or a
// consumer that already holds indices -- never has to walk the
// track->lane->range chain itself and get the nesting wrong.
keyframe_lane_key :: proc(clip: ^Clip, track_index, lane, key_index: int) -> Keyframe {
	return session_kf_at(
		keyframe_lane_view(session_trk_view(clip.keyframe_tracks, track_index), lane),
		key_index,
	)
}

// keyframe_lane_total is how many keys lane `i` holds -- the `total` a snapshot returns.
keyframe_lane_total :: proc(t: ^Keyframe_Track, i: int) -> int {
	return keyframe_lane_view(t, i).n
}

// --- lookups --------------------------------------------------------------

// keyframe_track_index returns the index of `name`'s track, or -1.
// The name is compared as TEXT against the track's borrowed view, deliberately
// not by interning the argument and comparing handles. Callers pass section
// names that are compile-time constants, and several of them look up a track
// that does not exist (render.odin asserts one is absent before minting it), so
// interning here would grow the session pool from a lookup -- a write on a read
// path, on a predicate clip_geom evaluates per frame. Borrowing costs a compare
// over a handful of lanes and allocates nothing.
keyframe_track_index :: proc(clip: Clip, name: string) -> int {
	n := clip.keyframe_tracks.n
	for i in 0 ..< n {
		if keyframe_track_name(session_trk_view(clip.keyframe_tracks, i)) == name {
			return i
		}
	}
	return -1
}

// Resolve writable key access through both COW layers before returning a
// pointer. Never retain returned pointer across a track/key store mutation.
// `lane` selects which of the track's scalar curves to write.
keyframe_key_mut :: proc(clip: ^Clip, track_index, lane, key_index: int) -> ^Keyframe {
	track := session_trk_view_mut(&clip.keyframe_tracks, track_index)
	assert(lane >= 0 && lane < len(track.lanes), "keyframe_key_mut: lane out of range")
	session_kf_make_unique(&track.lanes[lane].keys)
	return session_kf_at_ptr(track.lanes[lane].keys, key_index)
}

// keyframe_fill_snapshot copies `name`'s track into `dst` (a flat fixed array) up to
// its cap, returning (copied, total). This is how a cross-thread consumer
// (audio producer, render worker) gets an OWN copy of a track it samples per
// frame without ever touching the live timeline. The consumer that races the
// UI thread must memset-free nothing: dst is its own storage (a struct field),
// the copy is plain bytes. A consumer whose track may live in PACKED form
// snapshots through its own lane-aware entry point (keyframe_geom_fill_snapshot), so
// the worker seam stays packed-free.
keyframe_fill_snapshot :: proc(clip: ^Clip, name: string, dst: []Keyframe) -> (n, total: int) {
	ti := keyframe_track_index(clip^, name)
	if ti < 0 {
		return 0, 0
	}
	tk := session_trk_view(clip.keyframe_tracks, ti)
	// A plain keyed property is one lane. A GROUP track is several, and a consumer
	// asking for a group must snapshot one lane through keyframe_geom_fill_snapshot, which
	// knows the group's lane order -- asking here would silently merge two curves
	// into one array, so a group on this path is a bug and is caught.
	assert(
		len(tk.lanes) <= 1,
		"keyframe_fill_snapshot: a group track needs keyframe_geom_fill_snapshot (one lane), not the whole track",
	)
	if len(tk.lanes) == 0 {
		return 0, 0
	}
	keys := session_kf_view(tk.lanes[0].keys)
	total = len(keys)
	n = min(total, len(dst))
	if n > 0 {
		mem.copy(raw_data(dst[:n]), raw_data(keys), n * size_of(Keyframe))
	}
	return
}

// --- discrete edits (undo-seam callers) -------------------------------------

// keyframe_set_key records `value` on `name`'s track at frame_off (clip-relative),
// replacing any key already on that frame. Creates the track on first key; a
// second property mints its own track. The name is interned into the session
// pool, so the track owns no string and free_timeline has nothing to delete.
// Writes a SCALAR key on `name`'s own track; a consumer that groups names into
// packed tracks unwraps first (keyframe_geom_set_lane_key).
// keyframe_bump_structure flags that a keyframe sequence has shifted, invalidating
// any live index-based selection (see keyframe_view.structure_gen). Wrap to skip 0 so a
// full-cycle wrap can't accidentally match a selection made at gen 0.
keyframe_bump_structure :: proc() {
	keyframe_view.structure_gen += 1
	if keyframe_view.structure_gen == 0 {
		keyframe_view.structure_gen = 1
	}
}

keyframe_set_key :: proc(clip: ^Clip, name: string, frame_off: i32, value: f32) {
	keyframe_set_lane_key(clip, name, 0, frame_off, value)
}

// keyframe_set_lane_key records a scalar key on lane `lane` of `name`'s track with
// the default interpolation mode. See keyframe_set_lane_key_interp for the
// mode-preserving form the project loader uses.
keyframe_set_lane_key :: proc(
	clip: ^Clip,
	name: string,
	lane: int,
	frame_off: i32,
	value: f32,
) {
	keyframe_set_lane_key_interp(clip, name, lane, frame_off, value, .Cubic)
}

// keyframe_set_lane_key_interp records a scalar key on lane `lane` of `name`'s
// track, growing the track's lane list to reach it and keeping the key's own
// interpolation mode. A named scalar property uses lane 0; a group track
// (transform.x/.y, crop.l/.r/.t/.b) uses the lane's index in the group.
// Grow-then-write rather than assuming the lane exists, so a group's first key
// can arrive on any of its lanes.
//
// The interp parameter is why this is a proc of its own rather than a default
// argument: the project loader reads keys back with the easing the user set, and
// inserting them under the default would silently straighten every eased key on
// load.
keyframe_set_lane_key_interp :: proc(
	clip: ^Clip,
	name: string,
	lane: int,
	frame_off: i32,
	value: f32,
	interp: Keyframe_Interp,
) {
	assert(lane >= 0, "keyframe_set_lane_key_interp: lane must be >= 0")
	keyframe_bump_structure()
	ti := keyframe_track_index(clip^, name)
	if ti < 0 {
		session_trk_push(&clip.keyframe_tracks, Keyframe_Track {name = session_str_intern(name)})
		ti = clip.keyframe_tracks.n - 1
	}
	track := session_trk_view_mut(&clip.keyframe_tracks, ti)
	// Sharing first: this clip may be a copy that shares its keys with the clip it
	// came from, and writing before resolving that would edit both.
	session_trk_make_unique(&clip.keyframe_tracks)
	track = session_trk_view_mut(&clip.keyframe_tracks, ti)
	for lane >= len(track.lanes) {
		append(&track.lanes, Keyframe_Lane{})
	}
	session_kf_make_unique(&track.lanes[lane].keys)
	keys := track.lanes[lane].keys
	// Insertion point: last key at-or-before frame_off.
	ip := 0
	for ip < keys.n && session_kf_at(keys, ip).frame_off <= frame_off {
		ip += 1
	}
	if ip > 0 && session_kf_at(keys, ip - 1).frame_off == frame_off {
		session_kf_at_ptr(keys, ip - 1).value = value
		session_kf_at_ptr(keys, ip - 1).interp = interp
		track.lanes[lane].keys = keys
		return
	}
	// One call, replacing the append-a-sentinel-then-slide-the-tail dance. That
	// dance had to grow the array before the mem.copy so there would be a slot to
	// land in; get the order wrong and the key is silently dropped.
	session_kf_insert(
		&keys,
		ip,
		Keyframe {frame_off = frame_off, value = value, interp = interp},
	)
	// keys was re-windowed by the insert (the range can move); write it back so
	// the lane's own range tracks the new window.
	track = session_trk_view_mut(&clip.keyframe_tracks, ti)
	track.lanes[lane].keys = keys
}

// keyframe_track_has_keys reports whether any lane of `track` still holds a key.
// It is the liveness test for dropping a track: a section track with one keyed
// lane must survive, which is why this asks the lanes rather than lane 0.
keyframe_track_has_keys :: proc(track: ^Keyframe_Track) -> bool {
	for lane in 0 ..< len(track.lanes) {
		if track.lanes[lane].keys.n > 0 {
			return true
		}
	}
	return false
}

// keyframe_track_release_lanes frees every exclusively-held key array a track
// owns and drops the lane array itself. A shared array stays session-owned
// because another clip may still address it.
keyframe_track_release_lanes :: proc(track: ^Keyframe_Track) {
	for lane in 0 ..< len(track.lanes) {
		keys := track.lanes[lane].keys
		if keys.slots > 0 && !keys.shared {
			session_kf_release(keys)
		}
	}
	delete(track.lanes)
	track.lanes = nil
}

// keyframe_del_key removes the key at frame_off from `name`'s lane 0, where
// `name` is a TRACK name -- a section ("crop") or a plain property ("gain"). It
// drops the track once every lane empties (a track exists <=> it holds a key).
keyframe_del_key :: proc(clip: ^Clip, name: string, frame_off: i32) {
	keyframe_del_lane_key(clip, name, 0, frame_off)
}

// keyframe_del_lane_key removes the key at frame_off from one lane of `name`'s
// track. It is what a caller holding a LANE identity needs: the geometry layer
// resolves a property name to (section track, lane index) and deletes there, so
// dragging transform.y does not reach into transform.x's curve.
keyframe_del_lane_key :: proc(clip: ^Clip, name: string, lane, frame_off: i32) {
	keyframe_bump_structure()
	ti := keyframe_track_index(clip^, name)
	if ti < 0 {
		return
	}
	track := session_trk_view_mut(&clip.keyframe_tracks, ti)
	if lane >= 0 && lane < i32(len(track.lanes)) {
		keys := track.lanes[lane].keys
		session_kf_make_unique(&keys)
		for i in 0 ..< keys.n {
			if session_kf_at(keys, i).frame_off == frame_off {
				session_kf_erase(&keys, i)
				break
			}
		}
		track.lanes[lane].keys = keys
	}
	if !keyframe_track_has_keys(track) {
		// The lanes own their key arrays, and the deletion above only POPPED one:
		// pop shortens without releasing the buffer, so the lane still holds a
		// live allocation here. Dropping the row with ordered_remove then shifted
		// the tracks over it, orphaning that buffer for the life of the process —
		// one leaked key array per track that ever lost its last key, which the
		// memory gate reports from the undo probe (it is the only gate that runs
		// a path deleting keys down to empty). So the keys array is deleted here;
		// the name used to be deleted alongside it and no longer needs to be,
		// because it is a pool handle (TODO.md Active 19).
		keyframe_track_release_lanes(track)
		// name is a pool handle: no delete, and nothing to blank either -- the row
		// leaves the array on the next line.
		session_trk_erase(&clip.keyframe_tracks, ti)
	}
}

// --- curve math (easing + spline evaluators) -----------------------------

// keyframe_ease maps normalized segment time t∈[0,1] for the closed-form easing
// modes (.Cubic is a spline and is never routed here — keyframe_apply_interp
// resolves it). Elastic may push past [0,1]: that overshoot is the point.
keyframe_ease :: proc(interp: Keyframe_Interp, t: f32) -> f32 {
	switch interp {
	case .Cubic:
		// Hermite basis handles spline segments in keyframe_apply_interp.
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

// keyframe_chord_slope is the per-frame value slope of the straight line `a`→`b`
// (value/frame). It is the natural end condition for the spline: a missing
// neighbor defaults the tangent to the chord slope, which reduces cubic Hermite
// to plain linear interpolation on that end.
keyframe_chord_slope :: proc(a, b: Keyframe) -> f32 {
	return (b.value - a.value) / f32(b.frame_off - a.frame_off)
}

// keyframe_apply_interp evaluates one segment at normalized t∈[0,1], shaped by the
// arriving key's mode (the segment between l and r ends at r, so r owns the
// curve — the mode the keyframe readout selects). For .Cubic, m0/m1 are the
// per-frame tangent slopes at the endpoints, estimated by the caller from the
// neighbor keys and scaled to the segment by `span`; the Hermite basis then
// interpolates l→r with those tangents. Every other mode is l + (r−l)·keyframe_ease.
// `span` is in frames and always > 0 (adjacent keys are strictly sorted and
// distinct).
keyframe_apply_interp :: proc(l, r: f32, t: f32, interp: Keyframe_Interp, m0, m1: f32, span: f32) -> f32 {
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
		return l + (r - l) * keyframe_ease(interp, t)
	}
	return l
}

// --- evaluation (interpolated between keys, base before them, held after) --

// keyframe_sample_keys is the keyed evaluation over a flat key slice — the same
// algorithm keyframe_sample runs over a track, exposed separately so the audio
// producer re-evaluates keyed gain from its own snapshot (keyframe_fill_snapshot)
// without touching the live timeline. A key applies ITS value on its own
// frame; between two adjacent keys the value follows the NEXT key's
// interpolation mode (we ease INTO it) so it reaches that key's value exactly
// on its own frame.
//
// The two ends differ, and the difference is the point:
//   - BEFORE the first key the property is INACTIVE -- no key is being read, so
//     direct edits and drags still go to the caller's base/resting value -- but
//     the value itself INTERPOLATES from that base at offset 0 to the first key
//     on the first key's frame. The run-up is a segment like any other; only the
//     key routing stays on base.
//   - PAST the last key the track HOLDS its final value. A clip animated to a
//     new position stays there for the rest of its span rather than snapping
//     back to the pose it had before any key existed.
keyframe_sample_keys :: proc(keys: []Keyframe, frame_off: i32, base: f32) -> (f32, bool) {
	if len(keys) == 0 {
		return base, false
	}
	active := len(keys) - 1
	for active >= 0 && keys[active].frame_off > frame_off {
		active -= 1
	}
	if active < 0 {
		// The run-up from offset 0 to the first key is a real segment: the caller's
		// base on the clip's first frame, the first key's value on the first key's
		// frame, shaped by that first key's mode (we ease INTO it, as everywhere
		// else). A track whose first key is late used to sit at base for the whole
		// run-up, so the value jumped on the first key instead of arriving there.
		//
		// Still INACTIVE, and deliberately: `active` means the sampler is reading a
		// KEY here, and there is no key before the first one. That is what keeps a
		// pre-first-key write going to the resting field (clip_geom_set case 2)
		// instead of sprouting keys -- and the edit is still visible, because base is
		// this segment's starting value, so changing it moves the curve.
		//
		// Offset 0 is the segment's start, so an offset at or left of the clip edge
		// has nothing to interpolate over and is the base itself.
		first_key := keys[0]
		if frame_off <= 0 {
			return base, false
		}
		lead_span := f32(first_key.frame_off)
		lead_lv := base
		lead_rv := first_key.value
		lead_t := f32(frame_off) / lead_span
		// Tangents with no outside neighbour fall back to the chord, the same edge
		// condition the interior segments use. The right tangent can use the key
		// after the first one, measured from this segment's own start.
		lead_m0 := (lead_rv - lead_lv) / lead_span
		lead_m1 := lead_m0
		if len(keys) > 1 {
			lead_m1 = (keys[1].value - lead_lv) / f32(keys[1].frame_off)
		}
		return keyframe_apply_interp(lead_lv, lead_rv, lead_t, first_key.interp, lead_m0, lead_m1, lead_span), false
	}
	active_key := keys[active]
	if frame_off == active_key.frame_off {
		return active_key.value, true
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
		m0 := keyframe_chord_slope(active_key, next_key)
		if active >= 1 {
			prev_key := keys[active - 1]
			m0 = (next_key.value - prev_key.value) / f32(next_key.frame_off - prev_key.frame_off)
		}
		m1 := keyframe_chord_slope(active_key, next_key)
		if active + 2 < len(keys) {
			later_key := keys[active + 2]
			m1 = (later_key.value - active_key.value) / f32(later_key.frame_off - active_key.frame_off)
		}
		return keyframe_apply_interp(active_key.value, next_key.value, t, next_key.interp, m0, m1, span), true
	}
	// Past the last key the track HOLDS its final value — the animation's end
	// state is what the user keyed, and a clip that animated to a new position
	// must stay there. Dropping back to `base` here made a keyed clip snap to its
	// resting pose for the remainder of its span, which read as the keyframes
	// "not working" past their last frame.
	//
	// `base` still rules BEFORE the first key: there the track has not begun, so
	// the property is genuinely un-animated and a direct edit is what the user
	// is looking at. The asymmetry is deliberate — a track that has not started
	// has no end state to hold, one that has finished does.
	//
	// `active` is true, so clip_geom_set routes a write here to a KEY rather than
	// to the resting field. That is the invariant clip_geom.odin exists to keep:
	// a write goes wherever the sampler READS. With the tail holding, a drag
	// past the last key extends the animation instead of writing a value the
	// sampler would ignore.
	_ = base
	return active_key.value, true
}

// keyframe_sample_lane samples ONE lane of a track: the last key at-or-before the
// frame, interpolated toward the next, holding the final value past the last
// key. This replaces keyframe_sample_packed_lane, which existed only to extract one
// lane out of a [KF_PACK_MAX]f32 knot: with a track holding one scalar curve per
// lane, "sample lane idx" is just keyframe_sample_keys over that lane's own keys, so
// the two samplers collapse into one and the packed path is gone (TODO.md
// Active 52).
keyframe_sample_lane :: proc(track: ^Keyframe_Track, lane: int, frame_off: i32, base: f32) -> (f32, bool) {
	if track == nil {
		return base, false
	}
	keys := session_kf_view(keyframe_lane_view(track, lane))
	return keyframe_sample_keys(keys, frame_off, base)
}


// keyframe_sample evaluates the keyed value for clip-relative frame_off.
//
// A key applies ITS value on its own frame (creating or editing a keyframe is
// visible immediately); between two adjacent keys the value follows the NEXT
// key's interpolation mode (we ease INTO it) and arrives at that key's value
// exactly on its own frame. Past the last key the track holds its final value;
// before the first key the property is inactive and the caller keeps its own —
// direct edits and drags apply there. See keyframe_sample_keys for why the two ends
// differ.
// keyframe_sample samples lane 0 of a track. A plain property is one lane, so this
// is its whole curve; a section's other lanes are sampled through
// keyframe_sample_lane, which names the lane.
keyframe_sample :: proc(track: ^Keyframe_Track, frame_off: i32, base: f32) -> (f32, bool) {
	if track == nil || len(track.lanes) == 0 || track.lanes[0].keys.n == 0 {
		return base, false
	}
	return keyframe_sample_keys(session_kf_view(track.lanes[0].keys), frame_off, base)
}

// keyframe_sample_for resolves `name` against the clip and samples at a TIMELINE
// frame, relative to the clip start -- the caller-facing generic entry point.
// A consumer whose `name` may live inside a PACKED track samples through its
// own lane-aware entry point (keyframe_geom_sample_lane).
keyframe_sample_for :: proc(clip: ^Clip, name: string, timeline_frame: i64, base: f32) -> (f32, bool) {
	ti := keyframe_track_index(clip^, name)
	if ti < 0 {
		return base, false
	}
	return keyframe_sample(session_trk_view(clip.keyframe_tracks, ti), i32(timeline_frame - clip.timeline_start_frame), base)
}

// keyframe_free_tracks releases exclusively held track rows and key ranges. Shared
// ranges stay session-owned because another Clip may still address them.
keyframe_free_tracks :: proc(r: Keyframe_Track_Range) {
	if r.shared {
		return
	}
	for i in 0..<r.n {
		tracks := r
		keyframe_track_release_lanes(session_trk_view_mut(&tracks, i))
	}
	session_trk_release_range(r)
}

// keyframe_rebuild_tracks builds a fresh track array from src by filtering each
// track's keys to clip-relative [lo, hi) and re-relativizing survivors by -lo.
// Tracks left with no keys are dropped. src is untouched (its owner frees it
// after the halves are built), so the output shares no owned memory with it --
// the name, being a pool handle, is shared by design and needs no copy.
keyframe_rebuild_tracks :: proc(src: Keyframe_Track_Range, lo, hi: i32) -> Keyframe_Track_Range {
	out := Keyframe_Track_Range{}
	sn := src.n
	for si in 0..<sn {
		source := session_trk_view(src, si)^
		if !keyframe_track_has_keys(&source) {
			continue
		}
		// Each lane is filtered and re-relativized independently, so a section keeps
		// only the lanes that still have a key in the window -- a split that cuts
		// between two lanes' keys does not resurrect an empty one.
		rebuilt: Keyframe_Track
		rebuilt.name = source.name // pool handle
		for lane in 0 ..< len(source.lanes) {
			source_keys := source.lanes[lane].keys
			kept := Keyframe_Keys_Range{}
			for i in 0 ..< source_keys.n {
				k := session_kf_at(source_keys, i)
				if k.frame_off >= lo && k.frame_off < hi {
					// Preserve the interpolation mode: this is a NEW key, so dropping
					// interp would silently reset every eased/spline mode to the
					// default on split or trim.
					session_kf_push(
						&kept,
						Keyframe {
							frame_off = k.frame_off - lo,
							value     = k.value,
							interp    = k.interp,
						},
					)
				}
			}
			if kept.n > 0 {
				append(&rebuilt.lanes, Keyframe_Lane{keys = kept})
			} else {
				session_kf_release(kept)
			}
		}
		if len(rebuilt.lanes) > 0 {
			session_trk_push(&out, rebuilt)
		} else {
			delete(rebuilt.lanes)
		}
	}
	return out
}

// keyframe_split_preserve_continuity makes a split that lands MID-INTERPOLATION join the
// two halves back into one curve.
//
// keyframe_rebuild_tracks only PARTITIONS keys -- [0,cut) and [cut,MAX) -- which is
// correct for a lane that is HOLDING a value at the cut but severs a lane that is
// interpolating across it:
//
//   * the left half's last key is the last one before the cut, and the sampler
//     HOLDS that key past its own frame, so the tail sits at the key's value
//     instead of the value the curve was arriving at;
//   * the right half's first key is the first one after the cut, and the sampler
//     interpolates up to it from the resting value, so the head starts from the
//     clip's origin instead of from where the curve left off.
//
// So for each lane whose value AT the cut is interpolated -- a key on each side of
// it -- this writes the value the curve actually reads at the cut into BOTH
// boundaries: a key on the left half's final frame, and the right half's resting
// field. Neither half invents a value; both carry the curve's own, so the joined
// timeline reads exactly what it read before the split.
//
// A lane with keys on only ONE side of the cut is left alone: it is holding, not
// interpolating, and that half already agrees with the resting value.
//
// `src` is the PRE-SPLIT track range, which is the only thing that still holds
// the whole curve; `left` and `right` are the halves as the caller has just
// rebuilt them. Left is the ORIGINAL clip (its source range has been trimmed to
// the left span by now), so its resting fields are still the pre-split ones.
keyframe_split_preserve_continuity :: proc(src: Keyframe_Track_Range, left: ^Clip, right: ^Clip, cut: i32) {
	if cut <= 0 {
		return
	}
	for si in 0 ..< src.n {
		st := session_trk_view(src, si)
		// A section track is several lanes, so continuity is seeded PER LANE, not per
		// track: only the lanes that straddle the cut were severed, and a group key
		// writes every lane anyway, so seeding one lane of a group leaves the others
		// severed and moves the bug one level down. Iterating lanes is also what makes
		// the old packed-section skip unnecessary -- a section is no longer a knot with
		// two arms, it is N independent curves, and each is handled by the scalar path
		// already proven for `gain` (TODO.md Active 52).
		for li in 0 ..< len(st.lanes) {
			keys := session_kf_view(st.lanes[li].keys)
			// Only a lane straddling the cut can be severed by it. A lane whose keys
			// are all before (or all after) the cut is holding, and its surviving half
			// already agrees with the resting value -- seeding it would pin a constant
			// the curve never had.
			if len(keys) == 0 || keys[0].frame_off >= cut || keys[len(keys) - 1].frame_off < cut {
				continue
			}
			lane_name := keyframe_track_lane_name(st, li)
			base := keyframe_split_lane_base(left, lane_name)
			v, _ := keyframe_sample_keys(keys, cut, base)
			// LEFT: a key on its final frame, matching the last interpolation step
			// before the split. The left half's length is the cut itself, so its last
			// frame is cut-1.
			keyframe_set_lane_key(left, keyframe_track_name(st), li, cut - 1, v)
			// RIGHT: its ORIGIN property, so the next step interpolates from where
			// the curve arrived rather than from the pre-split resting value.
			keyframe_split_seed_origin(right, lane_name, v)
		}
	}
}

// keyframe_track_lane_name is the CONSUMER name of lane `li` of `st`: the property's
// name for a section lane, or the track's own name for a plain single-lane
// property. The resting-field lookups (keyframe_split_lane_base /
// keyframe_split_seed_origin) are keyed on these, so the reader and the writer resolve
// a lane the same way.
keyframe_track_lane_name :: proc(st: ^Keyframe_Track, li: int) -> string {
	if sec_index, ok := keyframe_geom_section_index(keyframe_track_name(st)); ok {
		defs := keyframe_geom_sections
		assert(
			li < len(defs[sec_index].lanes),
			"keyframe_track_lane_name: lane index exceeds the section's lane list",
		)
		return keyframe_lane_name(defs[sec_index].lanes[li])
	}
	return keyframe_track_name(st)
}

// keyframe_split_lane_prop resolves a keyframe track's NAME to the resting field it
// samples against. A section track (packed) has several lanes, so this is only
// meaningful for a lane that rides its OWN scalar track; a packed section is
// handled by its lanes, not by the section name.
//
// gain is the one non-geometry lane with a resting field, and it has no
// Render_Geom_Prop, so it is answered first and returns _COUNT to mean "not a
// geometry prop".
keyframe_split_lane_prop :: proc(name: string) -> Render_Geom_Prop {
	if name == "gain" {
		return ._COUNT
	}
	si, li, ok := keyframe_geom_section_for_lane(name)
	if !ok {
		return ._COUNT
	}
	defs := keyframe_geom_sections
	if si >= len(defs) || li >= len(defs[si].lanes) {
		return ._COUNT
	}
	return defs[si].lanes[li]
}

// keyframe_split_lane_base reads a lane name's resting value off a clip: geometry
// through clip_geom_resting, gain through its own field. A name with no resting
// field (or one this does not know) reads 0, which is the neutral the geometry
// samplers already assume for an un-keyed lane.
keyframe_split_lane_base :: proc(clip: ^Clip, name: string) -> f32 {
	p := keyframe_split_lane_prop(name)
	if p == ._COUNT {
		return name == "gain" ? clip.gain : 0.0
	}
	return clip_geom_resting(clip, p)
}

// keyframe_split_seed_origin writes a lane's RESTING value on the right half. Mirrors
// keyframe_split_lane_base so the two can never disagree about where a lane lives: a
// lane that is not read there is not written here.
keyframe_split_seed_origin :: proc(clip: ^Clip, name: string, v: f32) {
	p := keyframe_split_lane_prop(name)
	if p == ._COUNT {
		if name == "gain" {
			clip.gain = v
		}
		return
	}
	clip_geom_set_resting(clip, p, v)
}

// keyframe_trim_head drops keys on the trimmed head and re-relativizes the rest
// (a clip whose head was cut off and which shifted left by `cut`).
keyframe_trim_head :: proc(clip: ^Clip, cut: i32) {
	if clip.keyframe_tracks.n == 0 {
		return
	}
	keyframe_bump_structure()
	old := clip.keyframe_tracks
	clip.keyframe_tracks = keyframe_rebuild_tracks(old, cut, KF_MAX_OFFSET)
	keyframe_free_tracks(old)
}

// keyframe_trim_tail drops keys beyond the clip's new length (`keep` = new length);
// survivors keep their offsets.
keyframe_trim_tail :: proc(clip: ^Clip, keep: i32) {
	if clip.keyframe_tracks.n == 0 {
		return
	}
	keyframe_bump_structure()
	old := clip.keyframe_tracks
	clip.keyframe_tracks = keyframe_rebuild_tracks(old, 0, keep)
	keyframe_free_tracks(old)
}

// --- clip rows ---------------------------------------------------------------
//
// A ROW is one scalar key curve as the timeline draws it: a clip's rows are its
// keyframe tracks' LANES flattened in order. Rows used to be one per track, which
// worked only because a track held a single curve; a group track's lanes each
// need their own diamond and their own gutter label, so the flattened row index
// is what the painter, the hit-test and the gutter all speak (TODO.md Active 52).

// The three helpers take the clip's keyframe track RANGE, not the clip: rows are
// a property of the tracks alone, and a range is a plain value that a `for ... in`
// loop can hand over without asking for an addressable clip.

// keyframe_clip_rows is how many lane rows a clip draws.
keyframe_clip_rows :: proc(tracks: Keyframe_Track_Range) -> int {
	rows := 0
	for track_index in 0 ..< tracks.n {
		rows += len(session_trk_view(tracks, track_index).lanes)
	}
	return rows
}

// keyframe_clip_row resolves a flat row index to the (track, lane) it draws.
// Returns (-1, -1) for a row past the clip's last, so a caller bounding its row
// count separately cannot read out of range.
keyframe_clip_row :: proc(tracks: Keyframe_Track_Range, row_index: int) -> (track, lane: int) {
	remaining := row_index
	for track_index in 0 ..< tracks.n {
		n := len(session_trk_view(tracks, track_index).lanes)
		if remaining < n {
			return track_index, remaining
		}
		remaining -= n
	}
	return -1, -1
}

// keyframe_clip_row_name is the consumer name of a row's lane -- the label the
// timeline gutter shows and the name a lane's resting value resolves under.
keyframe_clip_row_name :: proc(tracks: Keyframe_Track_Range, row: int) -> string {
	track_index, lane_index := keyframe_clip_row(tracks, row)
	if track_index < 0 {
		return ""
	}
	return keyframe_track_lane_name(session_trk_view(tracks, track_index), lane_index)
}

// --- file mapping -----------------------------------------------------------
//
// The project file stores a keyframe track as a NAME plus a key array
// (Saved_Kf_Track); it has no notion of a group. A section track owns several
// lanes, so it crosses the boundary as SEVERAL named entries -- one per lane,
// each named after the property that lane is. The mapping is the same one the
// geometry layer uses, so a lane's file name and its on-screen name cannot drift.

// keyframe_file_track_lanes is how many file entries a track saves as.
keyframe_file_track_lanes :: proc(tracks: Keyframe_Track_Range, track_index: int) -> int {
	return len(session_trk_view(tracks, track_index).lanes)
}

// keyframe_file_lane_name is the name a lane saves under: the section lane's
// property name for a section track, the track's own name for a plain property.
keyframe_file_lane_name :: proc(tracks: Keyframe_Track_Range, track_index, lane: int) -> string {
	return keyframe_track_lane_name(session_trk_view(tracks, track_index), lane)
}

// keyframe_file_lane_keys copies one lane's keys into `dst`, returning
// (copied, total). The copy is a plain byte copy of scalar keys, so the encode
// does not depend on the session staying alive.
keyframe_file_lane_keys :: proc(
	tracks: Keyframe_Track_Range,
	track_index,
	lane: int,
	dst: []Keyframe,
) -> (n, total: int) {
	keys := session_kf_view(keyframe_lane_view(session_trk_view(tracks, track_index), lane))
	total = len(keys)
	n = min(total, len(dst))
	if n > 0 {
		mem.copy(raw_data(dst[:n]), raw_data(keys), n * size_of(Keyframe))
	}
	return
}

// keyframe_file_name_lane resolves a file entry's name to the (section track,
// lane index) it loads into, or ok=false for a plain property that loads into a
// track of its own name.
keyframe_file_name_lane :: proc(name: string) -> (section: string, lane: int, ok: bool) {
	if sec_index, lane_index, is_lane := keyframe_geom_section_for_lane(name); is_lane {
		defs := keyframe_geom_sections
		return defs[sec_index].name, lane_index, true
	}
	return "", 0, false
}

// keyframe_rows_for is how many keyframe rows a track's lane strip shows: the most
// rows any single clip in the track carries, so the strip is tall enough for the
// tallest clip. Clips with fewer rows leave their own strip shorter (the wrap is
// only as tall as it needs) and top-align with the rest of the row.
keyframe_rows_for :: proc(track: ^Track) -> int {
	rows := 0
	for &c in track.clips {
		if n := keyframe_clip_rows(c.keyframe_tracks); n > rows {
			rows = n
		}
	}
	return rows
}
