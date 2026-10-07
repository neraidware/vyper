// Session keyframe store: the key ranges that make `Clip` POD (TODO.md
// Active 19, S2b).
//
// A `Kf_Track` no longer owns its keys. It holds a `Kf_Keys_Range` — a window
// into one flat `[dynamic]Keyframe` owned by the session — so copying a clip is
// a struct copy and there is no per-clip payload to free. Every slot belongs to
// the session; a track's keys are a window onto it, and the window is what
// moves.
//
// WHY AN ALLOCATOR AND NOT A BUMP POINTER. Two reasons, both from what the
// callers actually do:
//   - Keys are INSERTED one at a time (auto-key on a drag, ripple edits). With
//     no capacity slack, an insert reallocates the whole range and copies it,
//     turning an amortized O(1) append into an O(n) memcpy on a path that runs
//     per edit frame. So a range reserves `slots` >= `n` and grows by doubling.
//   - Keys are DELETED constantly, and a deleted key must come back. Bump-only
//     storage leaks a range per delete for the life of the session, which for
//     ripple-editing is thousands of ranges an hour. So freed ranges return to a
//     free list and are reused.
// That makes this a first-fit allocator with coalescing, not a bump pointer, and
// the difference is not free: `session_kf_grow` MOVES a range when it cannot
// extend in place, so a borrowed `[]Keyframe` dies on grow. See
// `session_kf_view` for the rule that keeps that safe.
//
// WHY NOT S1's FIXED BLOCK. The string pool is fixed because `session_str_view`
// hands out long-lived aliases that callers capture all over the tree. Keys have
// the opposite shape: every read goes through a snapshot seam into a
// caller-owned fixed array (`Audio_Gain_Snapshot.keys`,
// `kf_geom_fill_snapshot`'s `slot.keys`), and the census found twelve borrowed
// key views, all consumed by the very next expression. So keys can live in
// relocatable storage, and reusing freed space matters more here than it did for
// strings. That asymmetry is the reason this file exists rather than a second
// field on `session_str`.
package main

import "core:mem"

// SESSION_KF_MAX_KEYS bounds LIVE keys (allocated slots, not the array's
// high-water mark) and is the exhaustion assert, not a preallocation: the array
// grows on demand, so a generous bound costs nothing until a project needs it.
// Freed ranges are reused, so this is a ceiling on the largest set of keys alive
// at once, not on the total ever written.
SESSION_KF_MAX_KEYS :: 1 << 20

// SESSION_KF_MIN_CAP is the floor on a range's reserved capacity. A track with
// three keys still reserves this many slots, so the first few inserts on a new
// track never move it. Pairs with the block grain of the session string pool:
// a handful of keys per name is the common case, and a per-track floor keeps a
// 200-lane clip from paying 200 separate growth moves.
SESSION_KF_MIN_CAP :: 8

// Kf_Keys_Range locates one track's keys in the session store. It travels inside
// a `Kf_Track`, which travels inside a `Clip`, which is why it must be POD: two
// ints of length, no pointer, nothing to free.
//
// The zero value is a valid empty range (no keys), so a fresh `Kf_Track` is
// usable without an init.
Kf_Keys_Range :: struct {
	// first: index of the first reserved slot in `session_kf_keys`.
	first: int,
	// slots: reserved capacity. Always >= n. The slack is what makes insert
	// amortized O(1); `n` alone is not an allocation.
	slots: int,
	// n: live keys, sorted ascending by frame_off. slots - n is free tailroom.
	n: int,
	// shared: COW. True once a second `Clip` (or undo snapshot) references this
	// range, which makes every range shared-on-first-copy. There is no
	// refcount: the session owns the slots and outlives every holder, so the
	// only question a write has to answer is "am I the only writer?", and a
	// bool answers it without a count that could drift.
	shared: bool,
}

// Session_Kf_Free is one reclaimed span in the free list: `cap` contiguous free
// slots starting at `off`. The list is kept sorted by `off` so `session_kf_free`
// can coalesce an adjacent pair in O(1) once it has found the insertion point.
Session_Kf_Free :: struct {
	off: int,
	cap: int,
}

session_kf_keys: [dynamic]Keyframe
session_kf_free_spans: [dynamic]Session_Kf_Free
// session_kf_live: slots currently reserved across all ranges. Tracked
// explicitly because `len(session_kf_keys)` is the high-water mark, which says
// nothing about how much is actually handed out.
session_kf_live: int
// session_kf_live_peak: the high-water mark of the above. The probe asserts this
// stays flat under delete/re-add churn — that is the property proving freed
// ranges are reused rather than leaked past the bound.
session_kf_live_peak: int
// session_kf_moves: how many times a grow had to relocate a range instead of
// extending it in place. Zero is the healthy steady state; the probe watches it
// because every move invalidates borrowed views, and a workload that moves on
// every insert means the in-place path is broken.
session_kf_moves: int

// session_kf_reset drops every range. Called from session teardown alongside
// session_str_reset. Blind rewind, for the reason recorded in TODO.md Active 19
// S0: no Clip, undo snapshot or timeline survives a session reset, so there is
// nothing to invalidate beyond asserting on the read side.
session_kf_reset :: proc() {
	clear(&session_kf_keys)
	clear(&session_kf_free_spans)
	session_kf_live = 0
	session_kf_live_peak = 0
	session_kf_moves = 0
}

// session_kf_live_keys is the live slot count, for the probe and for the
// exhaustion message.
session_kf_live_keys :: proc() -> int {
	return session_kf_live
}

// session_kf_alloc reserves `slots` contiguous slots and returns the first.
// First fit over the free list, else the tail. Callers pass a capacity, never a
// length: a zero-length range still needs a slot to append into, which is why
// this asserts rather than returning a sentinel.
session_kf_alloc :: proc(slots: int) -> int {
	assert(slots > 0, "session_kf_alloc: a range must reserve at least one slot")
	spans := &session_kf_free_spans
	for s, i in spans {
		if s.cap >= slots {
			off := s.off
			if rest := s.cap - slots; rest > 0 {
				spans[i] = Session_Kf_Free{off = off + slots, cap = rest}
			} else {
				ordered_remove(spans, i)
			}
			session_kf_live += slots
			session_kf_note_peak()
			return off
		}
	}
	assert(
		session_kf_live + slots <= SESSION_KF_MAX_KEYS,
		"session key store exhausted: live keys + requested would pass SESSION_KF_MAX_KEYS",
	)
	off := len(session_kf_keys)
	for _ in 0 ..< slots {
		append(&session_kf_keys, Keyframe{})
	}
	session_kf_live += slots
	session_kf_note_peak()
	return off
}

session_kf_note_peak :: proc() {
	if session_kf_live > session_kf_live_peak {
		session_kf_live_peak = session_kf_live
	}
}

// session_kf_free_at returns the capacity of the free span starting exactly at
// `off`, or 0 if that slot is not the head of a free span. This is the in-place
// growth probe: a range can extend itself only by eating the span immediately
// after it, and only if that span is free and big enough.
session_kf_free_at :: proc(off: int) -> int {
	for s in session_kf_free_spans {
		if s.off == off {
			return s.cap
		}
	}
	return 0
}

// session_kf_take removes `slots` from the head of the free span at `off`,
// leaving any remainder in place. The span must exist and be big enough; both
// are checked by the caller's free_at probe, and re-asserted here because a
// silent over-take would corrupt the free list for every later allocation.
session_kf_take :: proc(off: int, slots: int) {
	spans := &session_kf_free_spans
	for s, i in spans {
		if s.off == off {
			assert(s.cap >= slots, "session_kf_take: span smaller than the take")
			if rest := s.cap - slots; rest > 0 {
				spans[i] = Session_Kf_Free{off = off + slots, cap = rest}
			} else {
				ordered_remove(spans, i)
			}
			session_kf_live += slots
			session_kf_note_peak()
			return
		}
	}
	assert(false, "session_kf_take: no free span at that offset")
}

// session_kf_free returns `slots` starting at `off` to the free list, coalescing
// with the spans on either side so a run of adjacent frees becomes one span
// again. Without coalescing, interleaved alloc/free would fragment the store
// into thousands of unusable one-slot spans and `session_kf_alloc` would start
// appending past the bound.
session_kf_free :: proc(off: int, slots: int) {
	if slots <= 0 {
		return
	}
	assert(
		off >= 0 && off + slots <= len(session_kf_keys),
		"session_kf_free: span is outside the key store",
	)
	session_kf_live -= slots
	spans := &session_kf_free_spans
	// Insertion point: first span starting after `off`. The list is sorted, so
	// the neighbours to coalesce with are idx-1 and idx.
	idx := len(spans)
	for s, i in spans {
		if s.off > off {
			idx = i
			break
		}
	}
	append(spans, Session_Kf_Free{})
	// Shifting up is skipped when the new span landed at the end, which is the
	// common case: taking &spans[idx+1] regardless forms an address one past the
	// end of the slice, whatever the length argument says.
	if idx + 1 < len(spans) {
		mem.copy(&spans[idx + 1].off, &spans[idx].off, (len(spans) - idx - 1) * size_of(Session_Kf_Free))
	}
	spans[idx] = Session_Kf_Free{off = off, cap = slots}
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

// session_kf_grow makes a range of `slots` slots able to hold `need` keys,
// returning the (possibly new) offset and capacity. Growth doubles, so a track
// built one key at a time moves O(log n) times over its whole life instead of
// once per insert.
//
// The fast path is IN PLACE: if the span immediately after this range is free
// and large enough, the range eats it and keeps its offset. That is the common
// case for a freshly built track (the tail span was just freed, or nothing has
// been allocated past it yet) and it is the case that keeps borrowed views alive
// across growth. The slow path allocates, copies and frees — a relocation, which
// invalidates any borrowed view, hence session_kf_moves for the probe.
session_kf_grow :: proc(off: int, slots: int, need: int) -> (int, int) {
	if need <= slots {
		return off, slots
	}
	want := max(need, max(slots * 2, SESSION_KF_MIN_CAP))
	extra := want - slots
	if cap_after := session_kf_free_at(off + slots); cap_after >= extra {
		session_kf_take(off + slots, extra)
		return off, want
	}
	nf := session_kf_alloc(want)
	mem.copy(
		raw_data(session_kf_keys[nf:]),
		raw_data(session_kf_keys[off:]),
		slots * size_of(Keyframe),
	)
	session_kf_free(off, slots)
	session_kf_moves += 1
	return nf, want
}

// session_kf_view borrows a range's keys.
//
// THE RULE: the result is valid until the next session_kf_alloc, session_kf_free
// or relocating session_kf_grow on this range. Every current caller consumes it
// in the next expression — a sample, a fill into a caller-owned array, a
// comparison — and none stores it, which is what makes relocatable storage
// safe here. A caller that needs to hold keys across an edit must copy them out
// (that is what the snapshot seam already does). Do not add a proc that returns
// this view to be held.
// session_kf_window validates `r` and returns its first `n` entries. The one
// place a range is turned into a slice, because a mutator that re-slices
// `session_kf_keys` inline skips the check -- and the bounds check that
// `session_kf_erase`'s inline slice skipped is how an out-of-range window
// reached mem.copy instead of the assert naming it.
session_kf_window :: proc(r: Kf_Keys_Range, n: int) -> []Keyframe {
	assert(
		n >= 0 && n <= r.slots && r.first + r.slots <= len(session_kf_keys),
		"session range is out of bounds (stale handle after a reset?)",
	)
	return session_kf_keys[r.first : r.first + n]
}

session_kf_view :: proc(r: Kf_Keys_Range) -> []Keyframe {
	return session_kf_window(r, r.n)
}

// session_kf_keys_mut is session_kf_view for a range the caller owns
// exclusively. Asserting `!r.shared` here is the whole point of the COW bit: the
// one illegal mutation (writing through a shared range, which another clip or
// undo snapshot can also see) fails at the mutation site instead of silently
// corrupting a copy.
session_kf_view_mut :: proc(r: Kf_Keys_Range) -> []Keyframe {
	assert(!r.shared, "session_kf_view_mut: range is shared; make it unique first")
	return session_kf_view(r)
}

// session_kf_make_unique resolves COW for a range the caller is about to mutate,
// in place through the pointer. A shared range is copied into a fresh private
// one; an already-unique range is left alone, so the second edit to the same
// track does not pay for the copy. The copy starts at the same length, not a
// doubled capacity: this is a migration, not a growth, and the next insert will
// grow it if it needs to.
session_kf_make_unique :: proc(r: ^Kf_Keys_Range) {
	if !r.shared {
		return
	}
	slots := max(r.n, SESSION_KF_MIN_CAP)
	off := session_kf_alloc(slots)
	// Allocation may grow session_kf_keys and move every live range. Resolve
	// source only after allocation, from its stable range handle.
	src := session_kf_view(r^)
	mem.copy(
		raw_data(session_kf_keys[off:]),
		raw_data(src),
		r.n * size_of(Keyframe),
	)
	r^ = Kf_Keys_Range{first = off, slots = slots, n = r.n}
}

// session_kf_reserve grows a unique range so it can hold `need` keys, updating
// the handle. Split out from the grow sites because the handle lives inside a
// `Kf_Track` and every append has to write it back.
session_kf_reserve :: proc(r: ^Kf_Keys_Range, need: int) {
	if need <= r.slots {
		return
	}
	r.first, r.slots = session_kf_grow(r.first, r.slots, need)
}

// session_kf_release frees a range's slots. The caller must already have broken
// sharing — releasing a range another clip still points at would hand its slots
// to someone else. The store does not track holders, so that is a rule on the
// caller, and `kf_free_tracks` is the one place that owns whole clips.
session_kf_release :: proc(r: Kf_Keys_Range) {
	if r.slots > 0 {
		session_kf_free(r.first, r.slots)
	}
}

// session_kf_clone copies a range's live keys into a fresh private one. This is
// what a deep copy (undo snapshot, split half, project load) uses, and what
// `session_kf_make_unique` does when it resolves sharing.
session_kf_clone :: proc(r: Kf_Keys_Range) -> Kf_Keys_Range {
	if r.n == 0 && r.slots == 0 {
		return {}
	}
	slots := max(r.n, SESSION_KF_MIN_CAP)
	off := session_kf_alloc(slots)
	mem.copy(
		raw_data(session_kf_keys[off:]),
		raw_data(session_kf_view(r)),
		r.n * size_of(Keyframe),
	)
	return Kf_Keys_Range{first = off, slots = slots, n = r.n}
}

// session_kf_push appends one key to a range, growing in place when the slack
// allows and relocating when it does not. This is the insert primitive that
// replaces `append(&track.keys, k)` at the call sites.
//
// Growth happens BEFORE the write, not after: the handle is updated first, then
// the key lands at r.n in the (possibly new) slots. Writing first and growing
// after would put the key in the old range and then move it, which is the one
// ordering that loses the insert.
session_kf_push :: proc(r: ^Kf_Keys_Range, k: Keyframe) {
	assert(!r.shared, "session_kf_push: range is shared; make it unique first")
	session_kf_reserve(r, r.n + 1)
	session_kf_window(r^, r.n + 1)[r.n] = k
	r.n += 1
}

// session_kf_erase removes the key at `i`, shifting the rest down so the range
// stays sorted ascending. The freed slot becomes tailroom rather than being
// returned, so an erase/insert cycle on one track does not churn the store.
session_kf_erase :: proc(r: ^Kf_Keys_Range, i: int) {
	assert(!r.shared, "session_kf_erase: range is shared; make it unique first")
	assert(i >= 0 && i < r.n, "session_kf_erase: index out of range")
	keys := session_kf_window(r^, r.n)
	// Only when there is something to move. `&keys[i+1]` is evaluated whatever the
	// length argument says, so erasing the LAST key formed a pointer one past the
	// end of the slice and handed it to mem.copy with a length of 0. The bounds
	// check rejected the index; -no-bounds-check made it a pointer nobody looked
	// at.
	if i + 1 < r.n {
		mem.copy(&keys[i], &keys[i + 1], (r.n - i - 1) * size_of(Keyframe))
	}
	r.n -= 1
}

// session_kf_set overwrites the key at `i`. Distinct from push/erase because it
// asserts the index: a set is the "replace the key on this frame" edit, and a
// bad index there is a search bug, not a user error.
session_kf_set :: proc(r: ^Kf_Keys_Range, i: int, k: Keyframe) {
	assert(!r.shared, "session_kf_set: range is shared; make it unique first")
	assert(i >= 0 && i < r.n, "session_kf_set: index out of range")
	session_kf_window(r^, i + 1)[i] = k
}

// session_kf_at reads one key by index. Indexing the range through the store
// rather than through a slice is what keeps the call sites free of borrowed
// views; the bounds assert is the same one session_kf_view raises.
session_kf_at :: proc(r: Kf_Keys_Range, i: int) -> Keyframe {
	assert(i >= 0 && i < r.n, "session_kf_at: index out of range")
	return session_kf_keys[r.first + i]
}

// session_kf_at_ptr borrows one key in place, for the sites that mutate a single
// field (`k.value = v`) without replacing the whole key. Same lifetime rule as
// session_kf_view: do not hold this across a mutation of the range.
session_kf_at_ptr :: proc(r: Kf_Keys_Range, i: int) -> ^Keyframe {
	assert(!r.shared, "session_kf_at_ptr: range is shared; make it unique first")
	assert(i >= 0 && i < r.n, "session_kf_at_ptr: index out of range")
	return &session_kf_keys[r.first + i]
}

// session_kf_insert splices a key into a unique range at `i`, shifting the rest
// up. This replaces the append-a-sentinel-then-mem.copy-the-tail dance the
// ordered insert sites used, which had to grow the array before the slide so
// there was a slot to land in -- two chances to get the order wrong, and the
// wrong order silently drops the key.
session_kf_insert :: proc(r: ^Kf_Keys_Range, i: int, k: Keyframe) {
	assert(!r.shared, "session_kf_insert: range is shared; make it unique first")
	assert(i >= 0 && i <= r.n, "session_kf_insert: insert position out of range")
	session_kf_reserve(r, r.n + 1)
	// One past n: insert slides into the slot session_kf_reserve just made.
	keys := session_kf_window(r^, r.n + 1)
	// Same reason as session_kf_erase: appending at the end (i == r.n) has nothing
	// to slide, and forming &keys[i+1] anyway is the out-of-bounds address.
	if i < r.n {
		mem.copy(&keys[i + 1], &keys[i], (r.n - i) * size_of(Keyframe))
	}
	keys[i] = k
	r.n += 1
}

// session_kf_make builds a fresh private range holding `n` default keys. Replaces
// `make([dynamic]Keyframe, 0, cap)` followed by appends at the sites that build a
// track from a known key list.
session_kf_make :: proc(keys: []Keyframe) -> Kf_Keys_Range {
	r := Kf_Keys_Range{}
	if len(keys) > 0 {
		session_kf_reserve(&r, len(keys))
		mem.copy(
			raw_data(session_kf_keys[r.first :]),
			raw_data(keys),
			len(keys) * size_of(Keyframe),
		)
		r.n = len(keys)
	}
	return r
}
