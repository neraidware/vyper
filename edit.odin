package main

import "core:fmt"
import "core:strconv"
import clay "clay-odin"

// ---------------------------------------------------------------------------
// Inline editing of a clip property text field. editing_field is 1 (X), 2 (Y),
// 3 (Scale), 4..7 (crop L/R/T/B). Scale and the crop fields are normalized
// values but edit in percent-scale text (crop % of the box, Scale ×1), so both
// format/parse by the same 10^decimals factor.
edit_begin :: proc(field: int, value: f32) {
	editing_field = field
	prec := 0
	scaled := value
	switch field {
	case 3:
		prec = 2
	case 4, 5, 6, 7:
		scaled = value * 100
	}
	text := fmt.aprintf("%.*f", prec, scaled)
	edit_len = min(len(text), len(edit_chars))
	copy(edit_chars[:edit_len], text[:edit_len])
}

edit_cancel :: proc() {
	editing_field = 0
	edit_len = 0
}

// edit_field_over reports whether the pointer is still over the property field
// currently being edited (so a click-away outside it commits).
edit_field_over :: proc() -> bool {
	switch editing_field {
	case 1:
		return clay.PointerOver(clay.ID("PropFieldX"))
	case 2:
		return clay.PointerOver(clay.ID("PropFieldY"))
	case 3:
		return clay.PointerOver(clay.ID("PropFieldS"))
	case 4:
		return clay.PointerOver(clay.ID("PropCropL"))
	case 5:
		return clay.PointerOver(clay.ID("PropCropR"))
	case 6:
		return clay.PointerOver(clay.ID("PropCropT"))
	case 7:
		return clay.PointerOver(clay.ID("PropCropB"))
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
		case 1:
			sel.transform_x = value
		case 2:
			sel.transform_y = value
		case 3:
			sel.scale = max(value, 0.01)
		case 4:
			sel.crop_l = clamp(value / 100, 0, 1)
		case 5:
			sel.crop_r = clamp(value / 100, 0, 1)
		case 6:
			sel.crop_t = clamp(value / 100, 0, 1)
		case 7:
			sel.crop_b = clamp(value / 100, 0, 1)
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
