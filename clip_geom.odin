package main

// Clip geometry: ONE read path and ONE write path for the seven geometry
// properties (transform.x/y, scale, crop.l/r/t/b).
//
// Why this module exists. Every geometry property has two homes: a RESTING
// field on the Clip, and a keyframe track. Which one is authoritative depends
// on the playhead — kf_sample_keys returns the track's value between the first
// and last key and IGNORES the resting field there. So "write the resting
// field" is not always a no-op, but it is *silently* a no-op exactly when the
// property is keyed, which is the case a user reaches for when they want to
// animate a property.
//
// That made the routing a per-call-site responsibility: every geometry write
// had to remember to funnel through kf_auto_key, and the two preview gestures
// (crop_viewport_zoom for Alt+wheel, crop_viewport_pan for Alt+middle-drag)
// did not. The result was a drag that changed the inspector's numbers, moved
// nothing under the pointer, and made the clip jump when the playhead left the
// keyed span. geom_key_probe.odin gates exactly that.
//
// The invariant here, and the reason the loss is now structural rather than a
// discipline problem: a write goes wherever the sampler READS at the playhead.
// There is no code path that stores a value the sampler will ignore, because
// the routing predicate is the sampler's own `active` result — the same value
// the preview uses to decide what to draw.

// clip_geom_resting reads the clip's resting field for a lane. These scalars
// are the clip's static geometry: what it looks like where no keyframe
// applies, and what the project file persists alongside the tracks.
clip_geom_resting :: proc(clip: ^Clip, prop: Render_Geom_Prop) -> f32 {
	switch prop {
	case .Trans_X:
		return clip.transform_x
	case .Trans_Y:
		return clip.transform_y
	case .Scale:
		return clip.scale
	case .Crop_L:
		return clip.crop_l
	case .Crop_R:
		return clip.crop_r
	case .Crop_T:
		return clip.crop_t
	case .Crop_B:
		return clip.crop_b
	case ._COUNT:
		unreachable()
	}
	return 0
}

// clip_geom_set_resting writes the resting field. Only clip_geom_set and the
// drag paths that own a snapshot should call this — a caller reaching for it
// to bypass routing is the bug this module exists to make impossible.
clip_geom_set_resting :: proc(clip: ^Clip, prop: Render_Geom_Prop, v: f32) {
	switch prop {
	case .Trans_X:
		clip.transform_x = v
	case .Trans_Y:
		clip.transform_y = v
	case .Scale:
		clip.scale = v
	case .Crop_L:
		clip.crop_l = v
	case .Crop_R:
		clip.crop_r = v
	case .Crop_T:
		clip.crop_t = v
	case .Crop_B:
		clip.crop_b = v
	case ._COUNT:
		unreachable()
	}
}

// clip_geom_get is the value of a geometry property AT THE PLAYHEAD: the
// sampled keyframe where the property is keyed, else the resting field. This
// is what the user SEES, and every gesture that computes from geometry must
// read it here. Reading the resting field directly makes a drag compute from a
// base that is not on screen, so both the arithmetic and the store have to go
// through the playhead's value.
clip_geom_get :: proc(clip: ^Clip, prop: Render_Geom_Prop) -> f32 {
	v, _ := kf_geom_sample_lane(clip, kf_lane_name(prop), playhead.frame, clip_geom_resting(clip, prop))
	return v
}

// clip_geom_keyed_at reports whether the sampler is reading a KEY for this
// lane at the playhead. This is not "is the property keyed" — it is the exact
// question "would a resting write here be seen?", which is what the write
// routing needs to know, and which a bare kf_geom_prop_keyed gets wrong for a
// playhead outside the keyed span.
clip_geom_keyed_at :: proc(clip: ^Clip, prop: Render_Geom_Prop) -> bool {
	_, active := kf_geom_sample_lane(clip, kf_lane_name(prop), playhead.frame, clip_geom_resting(clip, prop))
	return active
}

// clip_geom_set writes one geometry property at the playhead, routed to
// wherever the clip will actually READ it. Returns true when a keyframe was
// written.
//
// The cases, in order of how much they matter:
//
//  1. The sampler is reading a key AT THE PLAYHEAD. Write a key. The auto-key
//     toggle is deliberately NOT consulted: with the toggle off, a resting
//     write would be discarded by the sampler, so the user's edit would vanish
//     while the gesture was still under the pointer. A visible edit must land
//     somewhere durable; for a property that is already animated, that
//     somewhere is the track.
//  2. The property is keyed but INACTIVE at the playhead (the playhead sits
//     before its first key or past its last). Auto-key extends the animation
//     here; without it the resting write is what the sampler reads, so the
//     edit is visible either way. Both are non-lossy, and this keeps the
//     toggle's meaning unchanged.
//  3. Not keyed. Write resting and mark the lane pending so "keyframe all
//     modified" can offer it. Auto-key never MINTS a track, matching
//     kf_auto_key's long-standing rule — a property nobody has keyed stays a
//     resting edit until the user asks for a key.
//
// No undo handling here: the caller opened an undo node when the gesture
// began, and its release-time push captures the whole drag including any key
// inserted along the way.
clip_geom_set :: proc(clip: ^Clip, prop: Render_Geom_Prop, v: f32) -> (keyed: bool) {
	// A key is only meaningful while the playhead is over the clip. kf_sample_keys
	// holds from the first key onward, so a playhead past the clip's end still
	// reads "active" and would otherwise collect keys on frames the clip does not
	// cover. The resting write below is correct there: it is what the sampler
	// reads, and the inspector's field is editable with the playhead anywhere.
	if !clip_visible_at(playhead.frame, clip.timeline_start_frame, clip.source_length_frames) {
		clip_geom_set_resting(clip, prop, v)
		clip.geom_modified |= 1 << uint(prop)
		return false
	}
	name := kf_lane_name(prop)
	if clip_geom_keyed_at(clip, prop) ||
	   (editor_flags.auto_keyframe && kf_geom_prop_keyed(clip, name)) {
		off := i32(playhead.frame - clip.timeline_start_frame)
		kf_geom_set_lane_key(clip, name, off, v)
		clip.geom_modified &= ~(1 << uint(prop))
		return true
	}
	clip_geom_set_resting(clip, prop, v)
	clip.geom_modified |= 1 << uint(prop)
	return false
}

// clip_geom_drag commits one lane of an in-flight drag. The drag functions
// write their computed value to the RESTING field as they go (they recompute
// from it every frame), and this is the single point where the result is
// routed to the playhead key if the property is keyed there.
//
// It replaces the autokey_gesture(sel, start, current, name) calls the
// gestures used to make, which gated the key write on the auto-key TOGGLE. On
// a keyed clip with the toggle off that meant the drag's resting write was
// discarded by the sampler: the handle followed the pointer, the preview did
// not move, and the clip snapped back on release. `start` is the drag's
// snapshot value, so an untouched lane is not committed — keying all four crop
// edges because the user grabbed one stamps keys nobody asked for.
clip_geom_drag :: proc(clip: ^Clip, prop: Render_Geom_Prop, start: f32) {
	v := clip_geom_resting(clip, prop)
	if v == start {
		return
	}
	clip_geom_set(clip, prop, v)
}

// clip_geom_mark_modified records that a lane was edited without a keyframe,
// so the inspector can offer to key it. Callers that write geometry through
// clip_geom_set or clip_geom_drag do not need it — both maintain the mask
// themselves — but a path that writes the resting field directly and owns its
// own keyframing (gain) uses the neighbouring clear to stay in step.
clip_geom_mark_modified :: proc(clip: ^Clip, prop: Render_Geom_Prop) {
	clip.geom_modified |= 1 << uint(prop)
}

// clip_geom_mark_keyed clears a lane's pending flag, for a path that keys
// outside clip_geom.odin and must not leave the lane looking pending.
clip_geom_mark_keyed :: proc(clip: ^Clip, prop: Render_Geom_Prop) {
	clip.geom_modified &= ~(1 << uint(prop))
}

// clip_geom_add_lane_key keys ONE geometry lane at the playhead, from the value
// currently on screen, and clears that lane's pending flag.
//
// Every geometry key-add button goes through here rather than calling
// kf_add_prop directly, because keying a lane and marking it keyed are ONE
// action: a lane that was panned (pending) and then manually keyed is no longer
// pending, and a button that left the bit set would keep "Key X" lit and
// re-key the lane on the next press. The gain diamond is not a geometry lane
// and still calls kf_add_prop.
clip_geom_add_lane_key :: proc(clip: ^Clip, prop: Render_Geom_Prop) {
	kf_add_prop(clip, kf_lane_name(prop), clip_geom_get(clip, prop))
	clip_geom_mark_keyed(clip, prop)
}

// clip_geom_add_group_key keys a whole packed SECTION at the playhead and
// clears every lane in it.
//
// The caller names the section, not the values: the lane list and its order
// come from kf_geom_sections, the same table kf_geom_set_packed reads the
// payload in. Spelling the seven values out at each call site would be a
// hand-written parallel copy of that table, and a lane added to a section would
// silently write the wrong slot.
clip_geom_add_group_key :: proc(clip: ^Clip, sec: string) {
	sec_index, ok := kf_geom_section_index(sec)
	assert(ok, "clip_geom_add_group_key: not a section name")
	// Bind the table to a local before indexing: kf_geom_sections is a
	// constant, and Odin will not index a constant with a variable.
	defs := kf_geom_sections
	sec_lanes := defs[sec_index].lanes
	lanes: [KF_PACK_MAX]f32
	for i in 0 ..< len(sec_lanes) {
		lanes[i] = clip_geom_get(clip, sec_lanes[i])
	}
	kf_add_group_prop(clip, sec, lanes)
	for i in 0 ..< len(sec_lanes) {
		clip_geom_mark_keyed(clip, sec_lanes[i])
	}
}

// clip_geom_key_modified reports whether a lane is a pending keyframe. Drives
// the per-lane diamond's "pending" tint, so the timeline shows the same set
// the button will key.
clip_geom_key_modified :: proc(clip: ^Clip, prop: Render_Geom_Prop) -> bool {
	return clip.geom_modified & (1 << uint(prop)) != 0
}

// clip_geom_any_modified reports whether ANY lane is pending. The "keyframe all
// modified" button is disabled when this is false rather than being a no-op
// click.
clip_geom_any_modified :: proc(clip: ^Clip) -> bool {
	return clip.geom_modified != 0
}

// clip_geom_can_key_all_modified reports whether the "keyframe all modified"
// button can do anything RIGHT NOW. Two conditions, and the second is not
// implied by the first: a lane must be pending, AND the playhead must be on
// the clip.
//
// The second one is the reason this is not just clip_geom_any_modified. The
// button writes keys at the playhead, and clip_geom_set's clip_visible_at guard
// exists precisely so that no edit can mint a key on a frame the clip does not
// cover. Keying from here would route straight around that guard. So off-clip
// the button is drawn dim and the click is ignored, and the pending set
// survives until the playhead comes back onto the clip — the edit is real and
// still worth keying, just not at a frame where the clip has no pixels.
clip_geom_can_key_all_modified :: proc(clip: ^Clip) -> bool {
	return clip_geom_any_modified(clip) &&
		clip_visible_at(playhead.frame, clip.timeline_start_frame, clip.source_length_frames)
}

// clip_geom_key_all_modified keys every pending lane at the playhead, in ONE
// undo node, and clears the pending set. The values come from clip_geom_get —
// the value currently on screen — not from the resting field, so pressing the
// button keys what the user sees rather than what the file happens to hold.
//
// Lanes are keyed individually rather than by section: a pending set is
// routinely a SUBSET of a section (one edge panned, three untouched), and
// folding a partial set into a packed section would convert the untouched
// lanes' scalar tracks for no reason. Returns the number of lanes keyed, so
// the caller can report a real result instead of pretending.
clip_geom_key_all_modified :: proc(clip: ^Clip) -> (n: int) {
	if clip.geom_modified == 0 {
		return 0
	}
	// The playhead must be on the clip: this writes keys at the playhead, and
	// clip_geom_set's clip_visible_at guard exists so no edit can mint an
	// off-clip key. The button's actionability is
	// clip_geom_can_key_all_modified's job (the click handler and the dimmed
	// diamond both consult it), so reaching here off-clip is a caller that
	// skipped the guard — assert rather than quietly keying a frame the clip
	// does not cover (§6: assert at the cause).
	assert(clip_visible_at(playhead.frame, clip.timeline_start_frame, clip.source_length_frames))
	// Sample every pending value BEFORE writing any key: kf_geom_set_lane_key
	// can unwrap a packed section, which changes what the subsequent reads
	// resolve to. Reading all first keeps the button's values the ones the
	// user was looking at when they pressed it.
	pending: [int(Render_Geom_Prop._COUNT)]f32
	for i in 0 ..< int(Render_Geom_Prop._COUNT) {
		prop := Render_Geom_Prop(i)
		if clip_geom_key_modified(clip, prop) {
			pending[i] = clip_geom_get(clip, prop)
		}
	}
	undo_begin()
	for i in 0 ..< int(Render_Geom_Prop._COUNT) {
		prop := Render_Geom_Prop(i)
		if clip_geom_key_modified(clip, prop) {
			kf_geom_set_lane_key(
				clip,
				kf_lane_name(prop),
				i32(playhead.frame - clip.timeline_start_frame),
				pending[i],
			)
			n += 1
		}
	}
	clip.geom_modified = 0
	undo_push(.Value, "Keyframe modified properties")
	return n
}
