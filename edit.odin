package main

import "core:fmt"
import "core:strconv"
import clay "clay-odin"

// ---------------------------------------------------------------------------
// Inline editing of a clip property text field. Scale and the crop fields are
// normalized values but edit in percent-scale text (crop % of the box, Scale
// ×1), so both format/parse by the same 10^decimals factor.
edit_begin :: proc(field: Edit_Field, value: f32) {
	editing_field = field
	prec := 0
	scaled := value
	switch field {
	case .X, .Y, .None:
	case .Scale:
		prec = 2
	case .Gain:
		prec = 1
	case .Crop_L, .Crop_R, .Crop_T, .Crop_B:
		scaled = value * 100
	}
	text := fmt.aprintf("%.*f", prec, scaled)
	edit_len = min(len(text), len(edit_chars))
	copy(edit_chars[:edit_len], text[:edit_len])
}

edit_cancel :: proc() {
	editing_field = .None
	edit_len = 0
}

// edit_field_over reports whether the pointer is still over the property field
// currently being edited (so a click-away outside it commits).
edit_field_over :: proc() -> bool {
	switch editing_field {
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
	case .None:
		return false
	}
	return false
}

edit_commit :: proc() {
	defer edit_cancel()
	val, parsed_ok := strconv.parse_f32(string(edit_chars[:edit_len]))
	if !parsed_ok {
		return
	}
	// The gain field is the one edit that targets audio clips, which
	// transformable_selected() rejects, so the clip resolves here and the
	// transformable guard applies per-field below.
	_, cl, ok := selected_clip()
	if !ok {
		return
	}
	// Resolve the edited field to its storage plus the clamped value and label.
	// A parse that changes nothing (click in, click out) is not an edit and must
	// not add a node, so the compare gates the commit below.
	field: ^f32
	label := "Edit clip transform"
	kind := Undo_Kind.Transform
	switch editing_field {
	case .X:
		if cl.kind == .Audio {
			return
		}
		field = &cl.transform_x
		label = "Set clip X"
	case .Y:
		if cl.kind == .Audio {
			return
		}
		field = &cl.transform_y
		label = "Set clip Y"
	case .Scale:
		if cl.kind == .Audio {
			return
		}
		field = &cl.scale
		val = max(val, 0.01)
		label = "Set clip scale"
	case .Crop_L:
		if cl.kind == .Audio {
			return
		}
		field = &cl.crop_l
		val = clamp(val / 100, 0, 1)
		label = "Set clip crop"
	case .Crop_R:
		if cl.kind == .Audio {
			return
		}
		field = &cl.crop_r
		val = clamp(val / 100, 0, 1)
		label = "Set clip crop"
	case .Crop_T:
		if cl.kind == .Audio {
			return
		}
		field = &cl.crop_t
		val = clamp(val / 100, 0, 1)
		label = "Set clip crop"
	case .Crop_B:
		if cl.kind == .Audio {
			return
		}
		field = &cl.crop_b
		val = clamp(val / 100, 0, 1)
		label = "Set clip crop"
	case .Gain:
		// Clamp to the knob range so the typed value and the knob's angle stay
		// consistent; the knob is the source of truth for what's reachable.
		val = clamp(val, f32(GAIN_MIN_DB), f32(GAIN_MAX_DB))
		field = &cl.gain
		label = "Set clip gain"
		kind = .Value
	case .None:
		return
	}
	if field^ == val {
		return
	}
	// Only gain edits touch audio; mirror them into the slab and let the
	// producer's live fold (audio_gain_epoch) apply them without re-provisioning.
	// A full note_edit() here re-seeded every decoder mid-playback whenever a
	// gain commit landed -- and dispatch_click_fallback commits in-flight field
	// edits on ANY fresh click, so selecting another clip re-opened all decoders.
	audio_changed := kind == .Value
	undo_begin()
	field^ = val
	undo_push(kind, label)
	if audio_changed {
		audio_geometry_commit()
	}
}

edit_append :: proc(ch: u8) {
	if edit_len < len(edit_chars) {
		edit_chars[edit_len] = ch
		edit_len += 1
	}
}

edit_backspace :: proc() {
	if edit_len > 0 {
		edit_len -= 1
	}
}
