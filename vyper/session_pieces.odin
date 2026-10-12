// Session-owned arena for a text clip's PIECES.
//
// A piece is a run of the clip's text that carries its own properties. Today
// that is one property -- its reveal window -- and the runs exist because the
// properties are per-piece by design: a curve owns its styling, so a run of
// text with one style is one piece, and a per-character property is a
// one-character piece rather than a special case.
//
// The reveal lives HERE rather than on the clip because a property with two
// possible owners is a property that will eventually disagree with itself: a
// text-level default plus per-piece overrides needs a rule for which wins, and
// the rule is the bug. One owner, always the piece.
//
// This is a session range rather than a [dynamic] on Clip for the reason markers
// and keyframe tracks are: Clip is POD and is copied by value in several places
// that each have to say what happens to the storage a copy points at. Sharing
// with first-write-separation is the rule the other two already follow, so
// pieces follow it instead of inventing a third.
//
// Rows are POD (two ints and a reveal), so a copied Clip's pieces separate on
// the first write to a piece, exactly as markers do.
package vyper

import "core:mem"

// Text_Piece is one run of a text clip's title.
//
// start and len are a range over the text's CHARACTER indices (the axis
// Text_Glyph.char_index counts), so a piece is a view of the clip's one text
// buffer and never owns any of it. Retyping the clip rebuilds that buffer and
// these ranges with it; the text itself is the only allocation.
Text_Piece :: struct {
	start: int,
	len:   int,
	// reveal: which characters of THIS piece are drawn, in PIECE-LOCAL
	// coordinates -- 0 is this piece's first character, not the text's.
	//
	// Piece-local is what makes retyping safe. A range stored against the text's
	// own coordinates would point at different characters after a retype, and
	// would do so silently: the animation would still play, over the wrong
	// letters. It also makes a reveal survive a rebuild for the same reason.
	//
	// The cost is that revealing the WHOLE text across several pieces is N ranges
	// rather than one. That is a authoring-time cost and not a data-model one, and
	// for the common case there is no N: text with one style is one piece.
	reveal: Text_Reveal,
}

// Text_Pieces_Range is a window into the session piece store. `shared` means a
// second Clip addresses these rows; the first write to one clones them.
Text_Pieces_Range :: struct {
	first:  int,
	slots:  int,
	n:      int,
	shared: bool,
}

SESSION_PIECE_MIN_CAP :: 4
SESSION_PIECE_MAX     :: 1 << 16

Session_Piece_Free :: struct {
	off:   int,
	slots: int,
}

session_piece_rows: [dynamic]Text_Piece
session_piece_free_spans: [dynamic]Session_Piece_Free
session_piece_live: int

session_piece_reset :: proc() {
	clear(&session_piece_rows)
	clear(&session_piece_free_spans)
	session_piece_live = 0
}

session_piece_alloc :: proc(slots: int) -> int {
	assert(slots > 0, "session_piece_alloc: zero-sized allocation")
	spans := &session_piece_free_spans
	for span, i in spans {
		if span.slots >= slots {
			off := span.off
			if rest := span.slots - slots; rest > 0 {
				spans[i] = Session_Piece_Free{off=off+slots, slots=rest}
			} else {
				ordered_remove(spans, i)
			}
			session_piece_live += slots
			return off
		}
	}
	off := len(session_piece_rows)
	assert(
		off + slots <= SESSION_PIECE_MAX,
		"session_piece_alloc: the piece store is full",
	)
	resize(&session_piece_rows, off + slots)
	session_piece_live += slots
	return off
}

session_piece_free :: proc(off, slots: int) {
	if slots <= 0 {
		return
	}
	assert(
		off >= 0 && off + slots <= len(session_piece_rows),
		"session_piece_free: span is outside the piece store",
	)
	session_piece_live -= slots
	spans := &session_piece_free_spans
	// Insertion point: first span starting after `off`. The list is sorted, so
	// the neighbours to coalesce with are idx-1 and idx.
	idx := len(spans)
	for span, i in spans {
		if span.off > off {
			idx = i
			break
		}
	}
	append(spans, Session_Piece_Free{off=off, slots=slots})
	// Shifting up is skipped when the new span landed at the end, which is the
	// common case: taking &spans[idx+1] regardless forms an address one past the
	// end of the slice, whatever the length argument says.
	if idx + 1 < len(spans) {
		mem.copy(
			&spans[idx+1].off,
			&spans[idx].off,
			(len(spans)-idx-1)*size_of(Session_Piece_Free),
		)
	}
	spans[idx] = Session_Piece_Free{off=off, slots=slots}
	// Coalesce forward, then backward. Order matters: merging forward first can
	// create a new adjacency with the backward neighbour.
	if idx + 1 < len(spans) {
		a, b := spans[idx], spans[idx+1]
		if a.off + a.slots == b.off {
			spans[idx].slots = a.slots + b.slots
			ordered_remove(spans, idx+1)
		}
	}
	if idx > 0 {
		p, c := spans[idx-1], spans[idx]
		if p.off + p.slots == c.off {
			spans[idx-1].slots = p.slots + c.slots
			ordered_remove(spans, idx)
		}
	}
}

session_piece_view :: proc(r: Text_Pieces_Range) -> []Text_Piece {
	assert(
		r.n >= 0 && r.n <= r.slots && r.first+r.slots <= len(session_piece_rows),
		"session_piece_view: stale/out-of-bounds range",
	)
	return session_piece_rows[r.first:r.first+r.n]
}

session_piece_at :: proc(r: Text_Pieces_Range, i: int) -> Text_Piece {
	assert(i >= 0 && i < r.n, "session_piece_at: index out of range")
	return session_piece_view(r)[i]
}

session_piece_at_mut :: proc(r: ^Text_Pieces_Range, i: int) -> ^Text_Piece {
	session_piece_make_unique(r)
	assert(i >= 0 && i < r.n, "session_piece_at_mut: index out of range")
	return &session_piece_rows[r.first+i]
}

session_piece_share :: proc(r: ^Text_Pieces_Range) -> Text_Pieces_Range {
	r.shared = true
	return r^
}

session_piece_clone_range :: proc(src: Text_Pieces_Range) -> Text_Pieces_Range {
	if src.n == 0 && src.slots == 0 {
		return {}
	}
	slots := max(src.slots, SESSION_PIECE_MIN_CAP)
	off := session_piece_alloc(slots)
	for i in 0 ..< src.n {
		session_piece_rows[off+i] = session_piece_rows[src.first+i]
	}
	return Text_Pieces_Range{first=off, slots=slots, n=src.n}
}

session_piece_make_unique :: proc(r: ^Text_Pieces_Range) {
	if !r.shared {
		return
	}
	r^ = session_piece_clone_range(r^)
}

session_piece_release :: proc(r: Text_Pieces_Range) {
	if !r.shared && r.slots > 0 {
		session_piece_free(r.first, r.slots)
	}
}

session_piece_push :: proc(r: ^Text_Pieces_Range, piece: Text_Piece) {
	session_piece_make_unique(r)
	if r.n == r.slots {
		new_slots := max(r.slots*2, SESSION_PIECE_MIN_CAP)
		new_off := session_piece_alloc(new_slots)
		for i in 0 ..< r.n {
			session_piece_rows[new_off+i] = session_piece_rows[r.first+i]
		}
		if r.slots > 0 {
			session_piece_free(r.first, r.slots)
		}
		r.first = new_off
		r.slots = new_slots
	}
	session_piece_rows[r.first+r.n] = piece
	r.n += 1
}

// session_piece_erase removes the piece at `i` and slides the rest, which is safe
// here in a way it was not for the lane store: a piece is addressed by NAME (its
// range in the text), not by position, so removing one does not renumber the
// others.
session_piece_erase :: proc(r: ^Text_Pieces_Range, i: int) {
	session_piece_make_unique(r)
	assert(i >= 0 && i < r.n, "session_piece_erase: index out of range")
	// Only when there is something to move: `&session_piece_rows[r.first+i+1]` is
	// evaluated whatever the length argument says, and on the last row of the
	// store that is a pointer past the end. Same trap as the other four stores.
	if i + 1 < r.n {
		mem.copy(
			&session_piece_rows[r.first+i],
			&session_piece_rows[r.first+i+1],
			(r.n-i-1)*size_of(Text_Piece),
		)
	}
	r.n -= 1
}