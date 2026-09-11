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
	case .None:
		return false
	}
	return false
}

edit_commit :: proc() {
	defer edit_cancel()
	if sel, ok := transformable_selected(); ok {
		value, ok := strconv.parse_f32(string(edit_chars[:edit_len]))
		if !ok {
			return
		}
		switch editing_field {
		case .X:
			sel.transform_x = value
		case .Y:
			sel.transform_y = value
		case .Scale:
			sel.scale = max(value, 0.01)
		case .Crop_L:
			sel.crop_l = clamp(value / 100, 0, 1)
		case .Crop_R:
			sel.crop_r = clamp(value / 100, 0, 1)
		case .Crop_T:
			sel.crop_t = clamp(value / 100, 0, 1)
		case .Crop_B:
			sel.crop_b = clamp(value / 100, 0, 1)
		case .None:
		}
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
