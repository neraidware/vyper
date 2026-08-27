package main

import "core:fmt"
import "core:strconv"

// ---------------------------------------------------------------------------
// Inline editing of a clip property text field (X/Y/Scale in the properties
// panel). editing_field/edit_chars/edit_len live in state.odin.
// ---------------------------------------------------------------------------

edit_begin :: proc(field: int, value: f32) {
	editing_field = field
	text := field == 3 ? fmt.aprintf("%.2f", value) : fmt.aprintf("%.0f", value)
	edit_len = min(len(text), len(edit_chars))
	copy(edit_chars[:edit_len], text[:edit_len])
}

edit_cancel :: proc() {
	editing_field = 0
	edit_len = 0
}

edit_commit :: proc() {
	defer edit_cancel()
	if sel, ok := transformable_selected(); ok {
		value, ok := strconv.parse_f32(string(edit_chars[:edit_len]))
		if !ok {
			return
		}
		if editing_field == 1 {
			sel.transform_x = value
		} else if editing_field == 2 {
			sel.transform_y = value
		} else if editing_field == 3 {
			sel.scale = max(value, 0.01)
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
