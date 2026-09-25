package main

import "core:strings"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// Generic modal text input. Any feature that needs raw string entry uses the
// global `ti` in state.odin: begin() opens the popup and routes keyboard/text
// input to it; Enter commits (via the caller's commit handler), Esc cancels.
// The field is deliberately plain — a raw editable string, UTF-8 safe, with
// cursor movement, selection, select-all, and system-clipboard copy/cut/paste.
// ---------------------------------------------------------------------------

// field buffer views
text_input_bytes :: proc() -> []u8 {
	return ti.buf[:]
}
text_input_string :: proc() -> string {
	return string(ti.buf[:])
}

// utf8_prev/utf8_next step to the previous/next character boundary in buf.
utf8_prev :: proc(buf: []u8, at: int) -> int {
	if at <= 0 {
		return 0
	}
	i := at - 1
	for i > 0 && (buf[i] & 0xC0) == 0x80 {
		i -= 1
	}
	return i
}
utf8_next :: proc(buf: []u8, at: int) -> int {
	if at >= len(buf) {
		return len(buf)
	}
	i := at + 1
	for i < len(buf) && (buf[i] & 0xC0) == 0x80 {
		i += 1
	}
	return i
}

// text_input_codepoints_before counts the UTF-8 characters before byte offset
// at (used to position the caret/selection in character-advance units).
text_input_codepoints_before :: proc(at: int) -> int {
	n := 0
	i := 0
	for i < at && i < len(ti.buf) {
		i = utf8_next(ti.buf[:], i)
		n += 1
	}
	return n
}

// text_input_set_buf replaces the whole buffer with s, caret at the end.
// Used by the cmdline match list to commit a highlighted file path.
text_input_set_buf :: proc(s: string) {
	clear(&ti.buf)
	append(&ti.buf, ..transmute([]u8)s)
	ti.cursor = len(ti.buf)
	ti.anchor = ti.cursor
}

// text_input_sel returns the selection as (start, end) byte offsets
// (start == end when nothing is selected).
text_input_sel :: proc() -> (int, int) {
	a, b := min(ti.anchor, ti.cursor), max(ti.anchor, ti.cursor)
	return a, b
}

// text_input_begin starts a fresh edit session, pre-filled with `initial`.
// input_type + target are caller discriminators resolved by the commit handler.
text_input_begin :: proc(initial: string, input_type: int, target: u64) {
	// Enable SDL text input for the session's lifetime so the IME never eats
	// global hotkeys while no field is open; text_input_commit/cancel turn it
	// back off. A re-begin while already editing keeps the current session.
	if !ti.active {
		_ = sdl.StartTextInput(app_window)
	}
	clear(&ti.buf)
	append(&ti.buf, ..transmute([]u8)initial)
	ti.cursor = len(ti.buf)
	ti.anchor = ti.cursor
	ti.input_type = input_type
	ti.target = target
	ti.is_create = false
	// A stale swallow from a previous ":"-opened session must not eat this
	// session's first typed character. The opener sets it again right after.
	ti.swallow_text = false
	// Each ":" session starts with a fresh fuzzy file list (walked lazily on
	// the first non-empty query) and a clear match highlight.
	if input_type == TI_CMDLINE {
		cmdline_match_reset()
	}
	ti.active = true
}

text_input_cancel :: proc() {
	if ti.active {
		_ = sdl.StopTextInput(app_window)
	}
	ti.active = false
	clear(&ti.buf)
	ti.cursor = 0
	ti.anchor = 0
}

// text_input_commit dismisses the field; the caller applies the value (based on
// input_type) from the buffer before it is cleared.
text_input_commit :: proc() {
	if ti.active {
		_ = sdl.StopTextInput(app_window)
	}
	ti.active = false
	ti.cursor = 0
	ti.anchor = 0
}

// text_input_remove_selection deletes the selected range, leaving the cursor at
// its start. Returns true if anything was removed.
text_input_remove_selection :: proc() -> bool {
	sm, lg := text_input_sel()
	if sm == lg {
		return false
	}
	copy(ti.buf[sm:], ti.buf[lg:])
	resize(&ti.buf, len(ti.buf) - (lg - sm))
	ti.cursor = sm
	ti.anchor = sm
	return true
}

// text_input_insert inserts bytes at the cursor, replacing any selection.
text_input_insert :: proc(s: string) {
	if len(s) == 0 {
		return
	}
	text_input_remove_selection()
	at := ti.cursor
	old_len := len(ti.buf)
	resize(&ti.buf, old_len + len(s))
	// Shift the tail right to make room.
	for i := old_len - 1; i >= at; i -= 1 {
		ti.buf[i + len(s)] = ti.buf[i]
	}
	copy(ti.buf[at:], s)
	ti.cursor = at + len(s)
	ti.anchor = ti.cursor
}

text_input_backspace :: proc() {
	if text_input_remove_selection() {
		return
	}
	if ti.cursor > 0 {
		p := utf8_prev(ti.buf[:], ti.cursor)
		copy(ti.buf[p:], ti.buf[ti.cursor:])
		resize(&ti.buf, len(ti.buf) - (ti.cursor - p))
		ti.cursor = p
		ti.anchor = p
	}
}

text_input_delete :: proc() {
	if text_input_remove_selection() {
		return
	}
	if ti.cursor < len(ti.buf) {
		nx := utf8_next(ti.buf[:], ti.cursor)
		copy(ti.buf[ti.cursor:], ti.buf[nx:])
		resize(&ti.buf, len(ti.buf) - (nx - ti.cursor))
	}
}

// text_input_move places the cursor at `pos`; unless shift is held the
// selection collapses. pos is clamped to the buffer.
text_input_move :: proc(pos: int, shift: bool) {
	ti.cursor = clamp(pos, 0, len(ti.buf))
	if !shift {
		ti.anchor = ti.cursor
	}
}

text_input_select_all :: proc() {
	ti.anchor = 0
	ti.cursor = len(ti.buf)
}

text_input_copy :: proc() {
	sm, lg := text_input_sel()
	if sm == lg {
		return
	}
	cstr, _ := strings.clone_to_cstring(string(ti.buf[sm:lg]))
	defer delete(cstr)
	_ = sdl.SetClipboardText(cstr)
}

text_input_cut :: proc() {
	text_input_copy()
	text_input_remove_selection()
}

text_input_paste :: proc() {
	cs := sdl.GetClipboardText()
	if cs == nil {
		return
	}
	n := 0
	for cs[n] != 0 {
		n += 1
	}
	pasted := string(cs[:n])
	// A single-line field drops newlines/carriage returns from the pasted text.
	out := make([dynamic]u8, 0, len(pasted))
	defer delete(out)
	for i := 0; i < len(pasted); i += 1 {
		if pasted[i] == '\n' || pasted[i] == '\r' {
			continue
		}
		append(&out, pasted[i])
	}
	text_input_insert(string(out[:]))
}

// Text_Input_Result reports what text_input_handle_key did so the caller can
// apply a committed value: .Consumed handled in-place, .Commit dismissed with
// the value ready in the buffer, .Cancel dismissed without applying, .None did
// not handle this key.
Text_Input_Result :: enum { None, Consumed, Commit, Cancel }

// text_input_handle_key routes a KEY_DOWN event while the field is active.
text_input_handle_key :: proc(key: sdl.Keycode, shift: bool, ctrl: bool) -> Text_Input_Result {
	switch key {
	case sdl.K_RETURN, sdl.K_RETURN2:
		text_input_commit()
		return .Commit
	case sdl.K_ESCAPE:
		text_input_cancel()
		return .Cancel
	case sdl.K_BACKSPACE:
		text_input_backspace()
		return .Consumed
	case sdl.K_DELETE:
		text_input_delete()
		return .Consumed
	case sdl.K_LEFT:
		text_input_move(utf8_prev(ti.buf[:], ti.cursor), shift)
		return .Consumed
	case sdl.K_RIGHT:
		text_input_move(utf8_next(ti.buf[:], ti.cursor), shift)
		return .Consumed
	case sdl.K_HOME:
		text_input_move(0, shift)
		return .Consumed
	case sdl.K_END:
		text_input_move(len(ti.buf), shift)
		return .Consumed
	case sdl.K_A:
		if ctrl {
			text_input_select_all()
			return .Consumed
		}
	case sdl.K_C:
		if ctrl {
			text_input_copy()
			return .Consumed
		}
	case sdl.K_X:
		if ctrl {
			text_input_cut()
			return .Consumed
		}
	case sdl.K_V:
		if ctrl {
			text_input_paste()
			return .Consumed
		}
	}
	return .None
}
