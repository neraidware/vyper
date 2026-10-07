// Session-owned arena for Clip marker rows. Labels are already session string
// handles, so each marker row is plain POD and clips carry only ranges.
package vyper

import "core:mem"

Clip_Markers_Range :: struct {
	first:  int,
	slots:  int,
	n:      int,
	shared: bool,
}

SESSION_MARKER_MIN_CAP :: 4
SESSION_MARKER_MAX     :: 1 << 20

Session_Marker_Free :: struct {
	off:   int,
	slots: int,
}

session_marker_rows: [dynamic]Clip_Marker
session_marker_free_spans: [dynamic]Session_Marker_Free
session_marker_live: int

session_marker_reset :: proc() {
	clear(&session_marker_rows)
	clear(&session_marker_free_spans)
	session_marker_live = 0
}

session_marker_alloc :: proc(slots: int) -> int {
	assert(slots > 0, "session_marker_alloc: zero-sized allocation")
	spans := &session_marker_free_spans
	for span, i in spans {
		if span.slots >= slots {
			off := span.off
			if rest := span.slots - slots; rest > 0 {
				spans[i] = Session_Marker_Free{off=off+slots, slots=rest}
			} else {
				ordered_remove(spans, i)
			}
			session_marker_live += slots
			return off
		}
	}
	assert(session_marker_live+slots <= SESSION_MARKER_MAX, "session marker arena exhausted")
	off := len(session_marker_rows)
	for _ in 0..<slots {
		append(&session_marker_rows, Clip_Marker{})
	}
	session_marker_live += slots
	return off
}

session_marker_free :: proc(off, slots: int) {
	if slots <= 0 { return }
	assert(off >= 0 && off+slots <= len(session_marker_rows), "session_marker_free: invalid span")
	session_marker_live -= slots
	spans := &session_marker_free_spans
	idx := len(spans)
	for span, i in spans {
		if span.off > off {
			idx = i
			break
		}
	}
	append(spans, Session_Marker_Free{})
	// Shifting up is skipped when the new span landed at the end, which is the
	// common case: taking &spans[idx+1] regardless forms an address one past the
	// end of the slice, whatever the length argument says. Same fix as the copy in
	// session_kf.odin -- these four pools grew as copies of each other, so the bug
	// came in four.
	if idx+1 < len(spans) {
		mem.copy(&spans[idx+1], &spans[idx], (len(spans)-idx-1)*size_of(Session_Marker_Free))
	}
	spans[idx] = Session_Marker_Free{off=off, slots=slots}
	if idx+1 < len(spans) && spans[idx].off+spans[idx].slots == spans[idx+1].off {
		spans[idx].slots += spans[idx+1].slots
		ordered_remove(spans, idx+1)
	}
	if idx > 0 && spans[idx-1].off+spans[idx-1].slots == spans[idx].off {
		spans[idx-1].slots += spans[idx].slots
		ordered_remove(spans, idx)
	}
}

session_marker_view :: proc(r: Clip_Markers_Range) -> []Clip_Marker {
	assert(r.n >= 0 && r.n <= r.slots && r.first+r.slots <= len(session_marker_rows), "session_marker_view: stale/out-of-bounds range")
	return session_marker_rows[r.first:r.first+r.n]
}

session_marker_at :: proc(r: Clip_Markers_Range, i: int) -> Clip_Marker {
	assert(r.n >= 0 && r.n <= r.slots && r.first+r.slots <= len(session_marker_rows), "session_marker_at: stale/out-of-bounds range")
	assert(i >= 0 && i < r.n, "session_marker_at: index out of range")
	return session_marker_rows[r.first+i]
}

session_marker_at_mut :: proc(r: ^Clip_Markers_Range, i: int) -> ^Clip_Marker {
	session_marker_make_unique(r)
	assert(r.n >= 0 && r.n <= r.slots && r.first+r.slots <= len(session_marker_rows), "session_marker_at_mut: stale/out-of-bounds range")
	assert(i >= 0 && i < r.n, "session_marker_at_mut: index out of range")
	return &session_marker_rows[r.first+i]
}

session_marker_share :: proc(r: ^Clip_Markers_Range) -> Clip_Markers_Range {
	r.shared = true
	return r^
}

session_marker_clone_range :: proc(src: Clip_Markers_Range) -> Clip_Markers_Range {
	if src.n == 0 && src.slots == 0 { return {} }
	slots := max(src.slots, SESSION_MARKER_MIN_CAP)
	off := session_marker_alloc(slots)
	for i in 0..<src.n {
		session_marker_rows[off+i] = session_marker_rows[src.first+i]
	}
	return Clip_Markers_Range{first=off, slots=slots, n=src.n}
}

session_marker_make_unique :: proc(r: ^Clip_Markers_Range) {
	if !r.shared { return }
	r^ = session_marker_clone_range(r^)
}

session_marker_release :: proc(r: Clip_Markers_Range) {
	if !r.shared && r.slots > 0 {
		session_marker_free(r.first, r.slots)
	}
}

session_marker_push :: proc(r: ^Clip_Markers_Range, m: Clip_Marker) {
	session_marker_make_unique(r)
	if r.n == r.slots {
		new_slots := max(r.slots*2, SESSION_MARKER_MIN_CAP)
		new_off := session_marker_alloc(new_slots)
		for i in 0..<r.n {
			session_marker_rows[new_off+i] = session_marker_rows[r.first+i]
		}
		if r.slots > 0 { session_marker_free(r.first, r.slots) }
		r.first = new_off
		r.slots = new_slots
	}
	session_marker_rows[r.first+r.n] = m
	r.n += 1
}

session_marker_erase :: proc(r: ^Clip_Markers_Range, i: int) {
	session_marker_make_unique(r)
	assert(i >= 0 && i < r.n, "session_marker_erase: index out of range")
	mem.copy(&session_marker_rows[r.first+i], &session_marker_rows[r.first+i+1], (r.n-i-1)*size_of(Clip_Marker))
	r.n -= 1
}

session_marker_from_slice :: proc(markers: []Clip_Marker) -> Clip_Markers_Range {
	r := Clip_Markers_Range{}
	for m in markers {
		session_marker_push(&r, m)
	}
	return r
}
