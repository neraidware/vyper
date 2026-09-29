package main

import "core:fmt"
import "core:strconv"
import clay "clay-odin"

// ---------------------------------------------------------------------------
// Inline editing of a clip property text field. Scale and the crop fields are
// normalized values but edit in percent-scale text (crop % of the box, Scale
// ×1), so both format/parse by the same 10^decimals factor.
edit_begin :: proc(field: Edit_Field, value: f32) {
	edit_state.field = field
	prec := 0
	scaled := value
	switch field {
	case .X, .Y, .None:
	case .Scale:
		prec = 2
	case .Kf_Value:
		prec = 2
	case .Gain:
		prec = 1
	case .Crop_L, .Crop_R, .Crop_T, .Crop_B:
		scaled = value * 100
	}
	// Format straight into the fixed field buffer. This used to be
	// fmt.aprintf followed by a copy into edit_state.chars, which allocated a
	// heap string that nothing owned -- every property focus leaked it, and the
	// copy made the allocation pointless.
	//
	// bprintf's builder is backed by the buffer with a nil allocator, so it
	// cannot allocate; it panics on overflow rather than truncating. That is
	// the behavior we want here: 64 bytes covers the worst case (an f32 at two
	// decimals is 43 characters), so it is unreachable, and a truncated field
	// would silently show a number other than the one the preview is using.
	// bprintf's builder takes its capacity from len(backing) and tracks its own
	// length, so pass the whole array -- [:0] would hand it a zero-capacity
	// buffer and every format would overflow.
	text := fmt.bprintf(edit_state.chars[:], "%.*f", prec, scaled)
	edit_state.len = len(text)
}

edit_cancel :: proc() {
	edit_state.field = .None
	edit_state.len = 0
}

// edit_field_over reports whether the pointer is still over the property field
// currently being edited (so a click-away outside it commits).
edit_field_over :: proc() -> bool {
	switch edit_state.field {
	case .X:
		return clay.PointerOver(clay.ID("PropFieldX"))
	case .Y:
		return clay.PointerOver(clay.ID("PropFieldY"))
	case .Scale:
		return clay.PointerOver(clay.ID("PropFieldS"))
	case .Crop_L:
		return clay.PointerOver(clay.ID("PropCropL"))
	case .Crop_R:
		return clay.PointerOver(clay.ID("PropCropR"))
	case .Crop_T:
		return clay.PointerOver(clay.ID("PropCropT"))
	case .Crop_B:
		return clay.PointerOver(clay.ID("PropCropB"))
	case .Gain:
		return clay.PointerOver(clay.ID("PropFieldGain"))
	case .Kf_Value:
		return clay.PointerOver(clay.ID("PropFieldKf"))
	case .None:
		return false
	}
	return false
}

edit_commit :: proc() {
	defer edit_cancel()
	val, parsed_ok := strconv.parse_f32(string(edit_state.chars[:edit_state.len]))
	if !parsed_ok {
		return
	}
	// Keyframe value edits target the keyframe selection, which is the ONLY
	// selection while active (S3 exclusivity) — so it can't ride the
	// selected_clip() resolve the clip fields use. A packed (section) key's
	// readout shows lane 0; editing it unwraps the section via
	// kf_geom_set_value, then lands the scalar on that lane. Undo snapshots the
	// whole timeline, so the replace is a plain commit.
	if edit_state.field == .Kf_Value {
		kcl, klane, k, kok := kf_selected()
		if !kok {
			return
		}
		lane_name := kcl.keyframe_tracks[klane].name
		frame := k.frame_off
		v0: f32
		if k.mask != 0 {
			v0, _ = kf_lane_value(k^, 0)
		} else {
			v0 = k.value.(f32)
		}
		if v0 == val {
			return
		}
		undo_begin()
		kf_geom_set_value(kcl, lane_name, frame, val)
		undo_push(.Value, "Set keyframe value")
		return
	}
	// The gain field is the one edit that targets audio clips, which
	// transformable_selected() rejects, so the clip resolves here and the
	// transformable guard applies per-field below.
	_, cl, ok := selected_clip()
	if !ok {
		return
	}
	// Resolve the edited field to its lane plus the clamped value and label.
	// A parse that changes nothing (click in, click out) is not an edit and must
	// not add a node, so the compare gates the commit below.
	//
	// Geometry lanes resolve to a Render_Geom_Prop and are written through
	// clip_geom_set, which routes the value to wherever the clip READS it at
	// the playhead. Writing the resting field here (as this did) silently
	// discarded the edit on any keyed property whenever auto-key was off, and
	// the field was seeded from the sampled value — so the user typed back the
	// number they could see and got no change. Gain is not a geometry lane and
	// keeps the direct write plus kf_auto_key.
	geom := Render_Geom_Prop._COUNT
	gain_field: ^f32
	label := "Edit clip transform"
	kind := Undo_Kind.Transform
	name := ""
	switch edit_state.field {
	case .X:
		if cl.kind == .Audio {
			return
		}
		geom = .Trans_X
		label = "Set clip X"
	case .Y:
		if cl.kind == .Audio {
			return
		}
		geom = .Trans_Y
		label = "Set clip Y"
	case .Scale:
		if cl.kind == .Audio {
			return
		}
		geom = .Scale
		val = max(val, 0.01)
		label = "Set clip scale"
	case .Crop_L:
		if cl.kind == .Audio {
			return
		}
		geom = .Crop_L
		val = clamp(val / 100, 0, 1)
		label = "Set clip crop"
	case .Crop_R:
		if cl.kind == .Audio {
			return
		}
		geom = .Crop_R
		val = clamp(val / 100, 0, 1)
		label = "Set clip crop"
	case .Crop_T:
		if cl.kind == .Audio {
			return
		}
		geom = .Crop_T
		val = clamp(val / 100, 0, 1)
		label = "Set clip crop"
	case .Crop_B:
		if cl.kind == .Audio {
			return
		}
		geom = .Crop_B
		val = clamp(val / 100, 0, 1)
		label = "Set clip crop"
	case .Gain:
		// Clamp to the knob range so the typed value and the knob's angle stay
		// consistent; the knob is the source of truth for what's reachable.
		val = clamp(val, f32(GAIN_MIN_DB), f32(GAIN_MAX_DB))
		gain_field = &cl.gain
		label = "Set clip gain"
		kind = .Value
		name = "gain"
	// Keyframe value edits are committed by the early return above, so this
	// case is unreachable — but the switch must stay exhaustive over the enum.
	case .Kf_Value, .None:
		return
	}
	// Compare against what the clip READS at the playhead, not the resting
	// field. On a keyed property the two differ, and the field was seeded from
	// the sampled value, so comparing the resting field made a no-op commit
	// look like a change and wrote a key the user never asked for.
	prev := f32(0)
	if geom != ._COUNT {
		prev = clip_geom_get(cl, geom)
	} else {
		prev = gain_field^
	}
	if prev == val {
		return
	}
	// Only gain edits touch audio; mirror them into the slab and let the
	// producer's live fold (audio_geom_state.gain_epoch) apply them without re-provisioning.
	// A full note_edit() here re-seeded every decoder mid-playback whenever a
	// gain commit landed -- and dispatch_click_fallback commits in-flight field
	// edits on ANY fresh click, so selecting another clip re-opened all decoders.
	audio_changed := kind == .Value
	undo_begin()
	if geom != ._COUNT {
		// clip_geom_set routes to the playhead key when the property is keyed
		// there, so the typed value lands on the timeline (a key already on the
		// frame is updated in place) instead of vanishing into a field the
		// sampler ignores. Same undo node as the resting write — the whole
		// field edit is one step.
		clip_geom_set(cl, geom, val)
	} else {
		gain_field^ = val
		kf_auto_key(cl, name, val)
	}
	undo_push(kind, label)
	if audio_changed {
		audio_geometry_commit()
	}
}

edit_append :: proc(ch: u8) {
	if edit_state.len < len(edit_state.chars) {
		edit_state.chars[edit_state.len] = ch
		edit_state.len += 1
	}
}

edit_backspace :: proc() {
	if edit_state.len > 0 {
		edit_state.len -= 1
	}
}
