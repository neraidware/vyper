// Session-owned arena for Clip keyframe track rows. Track ranges stay POD and
// travel with Clip; ranges are COW at clip-copy boundaries.
package main

import "core:mem"

Kf_Track_Range :: struct {
	first:  int,
	slots:  int,
	n:      int,
	shared: bool,
}

SESSION_TRK_MIN_CAP :: 4
SESSION_TRK_MAX     :: 1 << 20

Session_Trk_Free :: struct {
	off:   int,
	slots: int,
}

session_trk_rows: [dynamic]Kf_Track
session_trk_free_spans: [dynamic]Session_Trk_Free
session_trk_live: int

session_trk_reset :: proc() {
	clear(&session_trk_rows)
	clear(&session_trk_free_spans)
	session_trk_live = 0
}

session_trk_alloc :: proc(slots: int) -> int {
	assert(slots > 0, "session_trk_alloc: zero-sized allocation")
	spans := &session_trk_free_spans
	for span, i in spans {
		if span.slots >= slots {
			off := span.off
			if rest := span.slots - slots; rest > 0 {
				spans[i] = Session_Trk_Free{off = off + slots, slots = rest}
			} else {
				ordered_remove(spans, i)
			}
			session_trk_live += slots
			return off
		}
	}
	assert(session_trk_live + slots <= SESSION_TRK_MAX, "session track arena exhausted")
	off := len(session_trk_rows)
	for _ in 0..<slots {
		append(&session_trk_rows, Kf_Track{})
	}
	session_trk_live += slots
	return off
}

session_trk_free :: proc(off, slots: int) {
	if slots <= 0 { return }
	assert(off >= 0 && off + slots <= len(session_trk_rows), "session_trk_free: invalid span")
	session_trk_live -= slots
	spans := &session_trk_free_spans
	idx := len(spans)
	for span, i in spans {
		if span.off > off {
			idx = i
			break
		}
	}
	append(spans, Session_Trk_Free{})
	// Shifting up is skipped when the new span landed at the end, which is the
	// common case: taking &spans[idx+1] regardless forms an address one past the
	// end of the slice, whatever the length argument says. Same fix as the copy in
	// session_kf.odin -- these four pools grew as copies of each other, so the bug
	// came in four.
	if idx+1 < len(spans) {
		mem.copy(&spans[idx+1], &spans[idx], (len(spans)-idx-1)*size_of(Session_Trk_Free))
	}
	spans[idx] = Session_Trk_Free{off=off, slots=slots}
	if idx+1 < len(spans) && spans[idx].off+spans[idx].slots == spans[idx+1].off {
		spans[idx].slots += spans[idx+1].slots
		ordered_remove(spans, idx+1)
	}
	if idx > 0 && spans[idx-1].off+spans[idx-1].slots == spans[idx].off {
		spans[idx-1].slots += spans[idx].slots
		ordered_remove(spans, idx)
	}
}

session_trk_view :: proc(r: Kf_Track_Range, idx: int) -> ^Kf_Track {
	assert(r.n >= 0 && r.n <= r.slots && r.first+r.slots <= len(session_trk_rows), "session_trk_view: stale/out-of-bounds range")
	assert(idx >= 0 && idx < r.n, "session_trk_view: index out of range")
	return &session_trk_rows[r.first+idx]
}

session_trk_view_mut :: proc(r: ^Kf_Track_Range, idx: int) -> ^Kf_Track {
	session_trk_make_unique(r)
	return session_trk_view(r^, idx)
}

session_trk_share :: proc(r: ^Kf_Track_Range) -> Kf_Track_Range {
	r.shared = true
	return r^
}

session_trk_clone_range :: proc(src: Kf_Track_Range) -> Kf_Track_Range {
	if src.n == 0 && src.slots == 0 { return {} }
	slots := max(src.slots, SESSION_TRK_MIN_CAP)
	off := session_trk_alloc(slots)
	for i in 0..<src.n {
		session_trk_rows[off+i] = session_trk_rows[src.first+i]
		session_trk_rows[src.first+i].keys.shared = true
		session_trk_rows[off+i].keys.shared = true
	}
	return Kf_Track_Range{first=off, slots=slots, n=src.n}
}

session_trk_make_unique :: proc(r: ^Kf_Track_Range) {
	if !r.shared { return }
	r^ = session_trk_clone_range(r^)
}

session_trk_release_range :: proc(r: Kf_Track_Range) {
	if r.shared || r.slots == 0 { return }
	session_trk_free(r.first, r.slots)
}

session_trk_push :: proc(r: ^Kf_Track_Range, t: Kf_Track) {
	session_trk_make_unique(r)
	if r.n == r.slots {
		new_slots := max(r.slots*2, SESSION_TRK_MIN_CAP)
		new_off := session_trk_alloc(new_slots)
		for i in 0..<r.n {
			session_trk_rows[new_off+i] = session_trk_rows[r.first+i]
		}
		if r.slots > 0 { session_trk_free(r.first, r.slots) }
		r.first = new_off
		r.slots = new_slots
	}
	session_trk_rows[r.first+r.n] = t
	r.n += 1
}

session_trk_erase :: proc(r: ^Kf_Track_Range, idx: int) {
	session_trk_make_unique(r)
	assert(idx >= 0 && idx < r.n, "session_trk_erase: index out of range")
	mem.copy(&session_trk_rows[r.first+idx], &session_trk_rows[r.first+idx+1], (r.n-idx-1)*size_of(Kf_Track))
	r.n -= 1
}

session_trk_set :: proc(r: ^Kf_Track_Range, idx: int, t: Kf_Track) {
	session_trk_make_unique(r)
	assert(idx >= 0 && idx < r.n, "session_trk_set: index out of range")
	session_trk_rows[r.first+idx] = t
}

session_trk_insert :: proc(r: ^Kf_Track_Range, idx: int, t: Kf_Track) {
	session_trk_make_unique(r)
	assert(idx >= 0 && idx <= r.n, "session_trk_insert: index out of range")
	if r.n == r.slots {
		new_slots := max(r.slots*2, SESSION_TRK_MIN_CAP)
		new_off := session_trk_alloc(new_slots)
		for i in 0..<idx { session_trk_rows[new_off+i] = session_trk_rows[r.first+i] }
		for i in idx..<r.n { session_trk_rows[new_off+i+1] = session_trk_rows[r.first+i] }
		if r.slots > 0 { session_trk_free(r.first, r.slots) }
		r.first = new_off
		r.slots = new_slots
	} else {
		mem.copy(&session_trk_rows[r.first+idx+1], &session_trk_rows[r.first+idx], (r.n-idx)*size_of(Kf_Track))
	}
	session_trk_rows[r.first+idx] = t
	r.n += 1
}
