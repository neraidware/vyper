// Session-owned arena for a track's LANES. Same shape as session_kf.odin, one
// level up: a Keyframe_Track holds a window here, and that window is what moves.
//
// WHY A SESSION WINDOW AND NOT AN INLINE FIXED ARRAY. `Keyframe_Lane` used to be
// a fixed `[Keyframe_Lane_Max]Keyframe_Lane` inline in the track. The stated
// reason was that a session-pool row must "own no heap memory of its own" --
// which is false, and was worth believing. `Keyframe_Lane.keys` has always been a
// window into session_kf.odin, so a row already owned memory it did not store
// inline; what a row must not do is call the general allocator, because the
// session's teardown is a blind rewind. Those are different things and the rule
// conflated them, so an inline array was justified by a constraint that does not
// exist and paid for it on every track that has one lane.
//
// The cost of inline was not the copy in the erase -- that is inherent to any
// ordered container -- it was the SIZE. A `gain` track has one lane and occupied
// Keyframe_Lane_Max * size_of(Keyframe_Lane) bytes for it, on every track in the
// session, for a property most clips never key. The lane count is structural:
// `keyframe_geom_sections` is a compile-time table whose widest section is crop
// at 4, so the bound was 2x over before anything was measured.
//
// With a window, Keyframe_Track is a name handle plus a range handle, and a
// track that owns no lanes costs nothing at all.
//
// Lane order IS meaningful and must be preserved -- slot i is section lane i, so
// a group keeps its position even when a middle lane has no keys. That is why
// the mutators slide rather than swap, and why this store is not a set.
package vyper

import "core:mem"

// SESSION_LANE_MAX_LANES bounds LIVE lane slots across all tracks. Like
// SESSION_KF_MAX_KEYS it is an exhaustion assert on what is simultaneously
// reserved, not a preallocation; the array grows on demand.
SESSION_LANE_MAX_LANES :: 1 << 18

// SESSION_LANE_MIN_CAP is the floor on a range's reserved capacity. Paired with
// session_kf's: the common track owns one or two lanes, and a per-range floor
// keeps the first keying of a section track from relocating it.
SESSION_LANE_MIN_CAP :: 4

// Keyframe_Lanes_Range locates one track's lanes. POD, and it travels inside a
// Keyframe_Track, which travels inside a Clip, which is why it has no pointer.
//
// The zero value is a valid empty range, so a fresh Keyframe_Track is usable
// without an init.
Keyframe_Lanes_Range :: struct {
	// first: index of the first reserved slot in `session_lane_rows`.
	first: int,
	// slots: reserved capacity, always >= n. The slack is what makes append
	// amortized O(1); n alone is not an allocation.
	slots: int,
	// n: live lanes. Slot i is section lane i.
	n: int,
	// shared: COW. True once a second Clip or undo snapshot references this
	// range, which makes every range shared-on-first-copy. No refcount: the
	// session owns the slots and outlives every holder, so the only question a
	// write must answer is "am I the only writer?".
	shared: bool,
}

// Session_Lane_Free is one reclaimed span in the free list. Kept sorted by `off`
// so the free path can coalesce an adjacent pair in O(1).
Session_Lane_Free :: struct {
	off: int,
	cap: int,
}

session_lane_rows: [dynamic]Keyframe_Lane
session_lane_free_spans: [dynamic]Session_Lane_Free
session_lane_live: int
session_lane_live_peak: int

// session_lane_reset drops every range. Blind rewind: no Clip, undo snapshot or
// timeline survives a session reset, so there is nothing to invalidate beyond
// asserting on the read side.
session_lane_reset :: proc() {
	clear(&session_lane_rows)
	clear(&session_lane_free_spans)
	session_lane_live = 0
	session_lane_live_peak = 0
}
// session_lane_alloc reserves `slots` contiguous slots, first fit over the free
// list, else the tail. Callers pass a capacity and never a length: a zero-length
// range still needs a slot to append into.
session_lane_alloc :: proc(slots: int) -> int {
	assert(slots > 0, "session_lane_alloc: a range must reserve at least one slot")
	spans := &session_lane_free_spans
	for s, i in spans {
		if s.cap >= slots {
			off := s.off
			if rest := s.cap - slots; rest > 0 {
				spans[i] = Session_Lane_Free{off = off + slots, cap = rest}
			} else {
				ordered_remove(spans, i)
			}
			session_lane_live += slots
			session_lane_note_peak()
			return off
		}
	}
	assert(
		session_lane_live + slots <= SESSION_LANE_MAX_LANES,
		"session lane store exhausted: live lanes + requested would pass SESSION_LANE_MAX_LANES",
	)
	off := len(session_lane_rows)
	for _ in 0 ..< slots {
		append(&session_lane_rows, Keyframe_Lane{})
	}
	session_lane_live += slots
	session_lane_note_peak()
	return off
}

session_lane_note_peak :: proc() {
	if session_lane_live > session_lane_live_peak {
		session_lane_live_peak = session_lane_live
	}
}

// session_lane_free_at returns the capacity of the free span starting exactly at
// `off`, or 0. This is the in-place growth probe: a range extends itself only by
// eating the span immediately after it, and only if that span is free and big
// enough.
session_lane_free_at :: proc(off: int) -> int {
	for s in session_lane_free_spans {
		if s.off == off {
			return s.cap
		}
	}
	return 0
}

session_lane_take :: proc(off: int, slots: int) {
	spans := &session_lane_free_spans
	for s, i in spans {
		if s.off == off {
			assert(s.cap >= slots, "session_lane_take: span smaller than the take")
			if rest := s.cap - slots; rest > 0 {
				spans[i] = Session_Lane_Free{off = off + slots, cap = rest}
			} else {
				ordered_remove(spans, i)
			}
			session_lane_live += slots
			session_lane_note_peak()
			return
		}
	}
	assert(false, "session_lane_take: no free span at that offset")
}

// session_lane_free returns `slots` at `off` to the free list, coalescing with
// the spans on either side so a run of adjacent frees becomes one span again.
session_lane_free :: proc(off: int, slots: int) {
	if slots <= 0 {
		return
	}
	assert(
		off >= 0 && off + slots <= len(session_lane_rows),
		"session_lane_free: span is outside the lane store",
	)
	session_lane_live -= slots
	spans := &session_lane_free_spans
	// Insertion point: first span starting after `off`. The list is sorted, so
	// the neighbours to coalesce with are idx-1 and idx.
	idx := len(spans)
	for s, i in spans {
		if s.off > off {
			idx = i
			break
		}
	}
	append(spans, Session_Lane_Free{})
	// Shifting up is skipped when the new span landed at the end, which is the
	// common case: taking &spans[idx+1] regardless forms an address one past the
	// end of the slice, whatever the length argument says.
	if idx + 1 < len(spans) {
		mem.copy(
			&spans[idx + 1].off,
			&spans[idx].off,
			(len(spans) - idx - 1) * size_of(Session_Lane_Free),
		)
	}
	spans[idx] = Session_Lane_Free{off = off, cap = slots}
	// Coalesce forward, then backward. Order matters: merging forward first can
	// create a new adjacency with the backward neighbour.
	if idx + 1 < len(spans) {
		a, b := spans[idx], spans[idx + 1]
		if a.off + a.cap == b.off {
			spans[idx].cap = a.cap + b.cap
			ordered_remove(spans, idx + 1)
		}
	}
	if idx > 0 {
		p, c := spans[idx - 1], spans[idx]
		if p.off + p.cap == c.off {
			spans[idx - 1].cap = p.cap + c.cap
			ordered_remove(spans, idx)
		}
	}
}

// session_lane_grow returns a range of at least `need` slots, extending in place
// when the span after it is free and large enough, and relocating otherwise.
// A relocation moves the range and therefore invalidates any borrowed view; the
// capacity slack is what keeps that off the common path.
session_lane_grow :: proc(off: int, slots: int, need: int) -> (int, int) {
	if need <= slots {
		return off, slots
	}
	want := max(need, max(slots * 2, SESSION_LANE_MIN_CAP))
	extra := want - slots
	if cap_after := session_lane_free_at(off + slots); cap_after >= extra {
		session_lane_take(off + slots, extra)
		return off, want
	}
	nf := session_lane_alloc(want)
	mem.copy(
		raw_data(session_lane_rows[nf:]),
		raw_data(session_lane_rows[off:]),
		slots * size_of(Keyframe_Lane),
	)
	session_lane_free(off, slots)
	return nf, want
}

// session_lane_window validates `r` and returns its first `n` entries. The one
// place a range becomes a slice, because a mutator that re-slices
// session_lane_rows inline skips the check -- and an unvalidated window is how
// an out-of-range index reaches mem.copy instead of the assert naming it.
session_lane_window :: proc(r: Keyframe_Lanes_Range, n: int) -> []Keyframe_Lane {
	assert(
		n >= 0 && n <= r.slots && r.first + r.slots <= len(session_lane_rows),
		"session lane range is out of bounds (stale handle after a reset?)",
	)
	return session_lane_rows[r.first : r.first + n]
}

session_lane_view :: proc(r: Keyframe_Lanes_Range) -> []Keyframe_Lane {
	return session_lane_window(r, r.n)
}

session_lane_view_mut :: proc(r: Keyframe_Lanes_Range) -> []Keyframe_Lane {
	assert(!r.shared, "session_lane_view_mut: range is shared; make it unique first")
	return session_lane_window(r, r.n)
}

// session_lane_make_unique resolves COW for a track's lanes. A track row lives in
// session_trk_rows and is copied whole when a Clip is copied, so two rows can
// address one lane window; the first write has to break that.
session_lane_make_unique :: proc(r: ^Keyframe_Lanes_Range) {
	if !r.shared {
		return
	}
	slots := max(r.n, SESSION_LANE_MIN_CAP)
	off := session_lane_alloc(slots)
	// Allocation may grow session_lane_rows and move every live range. Resolve
	// the source only after allocation, from its stable range handle.
	src := session_lane_view(r^)
	mem.copy(
		raw_data(session_lane_rows[off:]),
		raw_data(src),
		r.n * size_of(Keyframe_Lane),
	)
	r^ = Keyframe_Lanes_Range{first = off, slots = slots, n = r.n}
}

session_lane_reserve :: proc(r: ^Keyframe_Lanes_Range, need: int) {
	if need <= r.slots {
		return
	}
	r.first, r.slots = session_lane_grow(r.first, r.slots, need)
}

// session_lane_release frees a range's slots. The caller must already have broken
// sharing. The store does not track holders, so that is a rule on the caller,
// and keyframe_free_tracks is the one place that owns whole clips.
session_lane_release :: proc(r: Keyframe_Lanes_Range) {
	if r.shared || r.slots == 0 {
		return
	}
	session_lane_free(r.first, r.slots)
}


// session_lane_push appends one lane. Growth happens BEFORE the write: the
// handle is updated first, then the lane lands at r.n in the (possibly new)
// slots. Writing first and growing after would put the lane in the old range
// and then move it, which is the one ordering that loses the push.
session_lane_push :: proc(r: ^Keyframe_Lanes_Range, lane: Keyframe_Lane) {
	session_lane_make_unique(r)
	session_lane_reserve(r, r.n + 1)
	session_lane_rows[r.first+r.n] = lane
	r.n += 1
}

// session_lane_erase removes the lane at `i`, sliding the tail left. The slide
// preserves order, which is the point: slot i is section lane i.
session_lane_erase :: proc(r: ^Keyframe_Lanes_Range, i: int) {
	session_lane_make_unique(r)
	assert(i >= 0 && i < r.n, "session_lane_erase: index out of range")
	// Only when there is something to move. `&rows[r.first+i+1]` is evaluated
	// whatever the length argument says, so erasing the LAST lane formed a
	// pointer one past the end of a range sitting flush against the store. The
	// bounds check stopped it; -no-bounds-check would not have.
	if i + 1 < r.n {
		mem.copy(
			&session_lane_rows[r.first+i],
			&session_lane_rows[r.first+i+1],
			(r.n-i-1)*size_of(Keyframe_Lane),
		)
	}
	r.n -= 1
}
session_lane_at :: proc(r: Keyframe_Lanes_Range, i: int) -> Keyframe_Lane {
	assert(i >= 0 && i < r.n, "session_lane_at: index out of range")
	return session_lane_view(r)[i]
}

// session_lane_at_ptr does NOT resolve COW, matching session_kf_at_ptr: `r`
// arrives by value, so cloning through it would mutate a copy and the caller
// would keep addressing the shared window. The caller owns that decision --
// keyframe_lane_at_mut is the only path that hands out a mutable lane, and it
// clones before calling here.
session_lane_at_ptr :: proc(r: Keyframe_Lanes_Range, i: int) -> ^Keyframe_Lane {
	assert(!r.shared, "session_lane_at_ptr: window is shared; make it unique first")
	assert(i >= 0 && i < r.n, "session_lane_at_ptr: index out of range")
	return &session_lane_view_mut(r)[i]
}

// session_lane_insert puts `lane` at index `i`, sliding the tail right. Inserting
// at the end has nothing to slide, and `&rows[r.first+i+1]` would be formed past
// the range's own last slot for a zero-length copy.
session_lane_insert :: proc(r: ^Keyframe_Lanes_Range, i: int, lane: Keyframe_Lane) {
	session_lane_make_unique(r)
	assert(i >= 0 && i <= r.n, "session_lane_insert: index out of range")
	if r.n == r.slots {
		want := max(r.n + 1, max(r.slots * 2, SESSION_LANE_MIN_CAP))
		nf := session_lane_alloc(want)
		for j in 0 ..< i {
			session_lane_rows[nf+j] = session_lane_rows[r.first+j]
		}
		for j in i ..< r.n {
			session_lane_rows[nf+j+1] = session_lane_rows[r.first+j]
		}
		session_lane_free(r.first, r.slots)
		r.first, r.slots = nf, want
	} else if i < r.n {
		mem.copy(
			&session_lane_rows[r.first+i+1],
			&session_lane_rows[r.first+i],
			(r.n-i)*size_of(Keyframe_Lane),
		)
	}
	session_lane_rows[r.first+i] = lane
	r.n += 1
}
