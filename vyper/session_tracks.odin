// Session-owned arena for Clip keyframe track rows. Track ranges stay POD and
// travel with Clip; ranges are COW at clip-copy boundaries.
package vyper

import "core:mem"

Keyframe_Track_Range :: struct {
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

session_trk_rows: [dynamic]Keyframe_Track
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
		append(&session_trk_rows, Keyframe_Track{})
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

session_trk_view :: proc(r: Keyframe_Track_Range, idx: int) -> ^Keyframe_Track {
	assert(r.n >= 0 && r.n <= r.slots && r.first+r.slots <= len(session_trk_rows), "session_trk_view: stale/out-of-bounds range")
	assert(idx >= 0 && idx < r.n, "session_trk_view: index out of range")
	return &session_trk_rows[r.first+idx]
}

session_trk_view_mut :: proc(r: ^Keyframe_Track_Range, idx: int) -> ^Keyframe_Track {
	session_trk_make_unique(r)
	return session_trk_view(r^, idx)
}

session_trk_share :: proc(r: ^Keyframe_Track_Range) -> Keyframe_Track_Range {
	r.shared = true
	return r^
}

session_trk_clone_range :: proc(src: Keyframe_Track_Range) -> Keyframe_Track_Range {
	if src.n == 0 && src.slots == 0 { return {} }
	slots := max(src.slots, SESSION_TRK_MIN_CAP)
	off := session_trk_alloc(slots)
	for i in 0..<src.n {
		session_trk_rows[off+i] = session_trk_rows[src.first+i]
		// The struct copy carries the lanes INLINE (they are a fixed slot array, not
		// a heap buffer), so every row owns its own headers and a write-back through
		// one row can never be visible through another. Only the key RANGES stay
		// shared -- that is the COW, and it is the whole point: a copied track shares
		// the key ARENA windows until one of them writes.
		for lane in 0 ..< session_trk_rows[off+i].lane_count {
			session_trk_rows[src.first+i].lanes[lane].keys.shared = true
			session_trk_rows[off+i].lanes[lane].keys.shared = true
		}
	}
	return Keyframe_Track_Range{first=off, slots=slots, n=src.n}
}

session_trk_make_unique :: proc(r: ^Keyframe_Track_Range) {
	if !r.shared { return }
	r^ = session_trk_clone_range(r^)
}

session_trk_release_range :: proc(r: Keyframe_Track_Range) {
	if r.shared || r.slots == 0 { return }
	session_trk_free(r.first, r.slots)
}

session_trk_push :: proc(r: ^Keyframe_Track_Range, t: Keyframe_Track) {
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

session_trk_erase :: proc(r: ^Keyframe_Track_Range, idx: int) {
	session_trk_make_unique(r)
	assert(idx >= 0 && idx < r.n, "session_trk_erase: index out of range")
	// Only when there is something to move, and for the same reason
	// session_kf_erase guards its copy: `&session_trk_rows[r.first+idx+1]` is
	// evaluated whatever the length argument says, so erasing the LAST track of a
	// range sitting at the end of the store formed a pointer past the end of the
	// global array and handed it to mem.copy with a length of 0. The bounds check
	// stopped it; -no-bounds-check would have made it a pointer nobody looked at.
	//
	// This was fixed in session_kf and missed here -- the same pattern in two
	// stores, which is the shape that lets one keep the bug.
	if idx + 1 < r.n {
		mem.copy(
			&session_trk_rows[r.first+idx],
			&session_trk_rows[r.first+idx+1],
			(r.n-idx-1)*size_of(Keyframe_Track),
		)
	}
	r.n -= 1
}

session_trk_set :: proc(r: ^Keyframe_Track_Range, idx: int, t: Keyframe_Track) {
	session_trk_make_unique(r)
	assert(idx >= 0 && idx < r.n, "session_trk_set: index out of range")
	session_trk_rows[r.first+idx] = t
}

session_trk_insert :: proc(r: ^Keyframe_Track_Range, idx: int, t: Keyframe_Track) {
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
	} else if idx < r.n {
		// Same one-past-the-end guard as the erases: inserting AT THE END has
		// nothing to shift, and `&...rows[r.first+idx+1]` is evaluated regardless
		// of the length, so it formed a pointer past the row the range owns.
		mem.copy(
			&session_trk_rows[r.first+idx+1],
			&session_trk_rows[r.first+idx],
			(r.n-idx)*size_of(Keyframe_Track),
		)
	}
	session_trk_rows[r.first+idx] = t
	r.n += 1
}
