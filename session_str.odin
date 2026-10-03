package main

// Session_Str is the session-scoped string pool: one block holding every interned
// clip name, marker label and keyframe track name for the life of the session.
//
// Before this, each of those was a heap `string` owned by the struct that held
// it. That made a Clip copy a deep copy: clip_deep_copy had to clone the name,
// clip_payload_free had to delete it, and every site that dropped a clip had to
// remember which proc owned the free. The compiler cannot see a forgotten free,
// and the next clip field that grows a payload re-opens the same class of bug
// (TODO.md Active 19).
//
// The pool removes the ownership, not the data. A Clip holds a handle instead of
// a `string`; nothing owns those bytes, nothing frees them, and copying a Clip
// is a struct copy.
//
// ---------------------------------------------------------------------------
// Why the block is FIXED-SIZE and never grows
// ---------------------------------------------------------------------------
// session_str_view returns a string ALIASING the pool, because a read site must
// not allocate -- that is the point of the refactor. An alias is only safe while
// the bytes stay put, and a [dynamic]u8 does not promise that: the first append
// that outgrows its capacity reallocates and every live view dangles. The probe
// caught exactly that (a view captured before an intern read back as freed heap
// garbage), and no amount of care at the call sites fixes it, because the caller
// cannot tell a moved buffer from a still one.
//
// So the pool is a fixed block carved from one end. That is the whole trick: a
// bump allocator whose storage never moves makes every alias valid for the
// session, which is exactly the lifetime a clip name needs. Growth is an assert
// at a named bound, not a reallocation -- and per TODO.md §6 a loud stop at the
// real limit beats a silent corruption three subsystems later.
//
// SESSION_STR_POOL_BYTES is sized from the real thing: a name is a filename
// component or a short typed title (~30 bytes with the handle table), so 1 MiB
// holds tens of thousands of distinct strings. A 10k-clip project with chapter
// markers lands a few hundred KiB in. Past that, the assert names the constant
// and someone raises it deliberately.
//
// Cleared by session_str_reset, which a project load or new triggers via
// session_teardown. Every handle issued before that is dead, so nothing
// surviving a reset may hold one -- which holds because no Clip value outlives
// the timeline: undo snapshots are freed before the reset and never touch disk
// (TODO.md Active 19, step 0). A stale handle is caught by session_str_view's
// bound assert, not by returning empty: reset sets used to 0, so the bytes a
// stale handle names are no longer part of the pool at all.

// SESSION_STR_MAX_LEN bounds one interned string. The longest thing interned in
// practice is a clip's display name -- a filename component (NAME_MAX is 255) or
// a title a person typed -- so nothing real comes near this. It exists to turn
// "something interned a buffer" into an assert at the intern site instead of a
// silently truncated name (TODO.md §6: truncating into a fixed buffer is silent
// data loss unless something says so happened).
SESSION_STR_MAX_LEN :: 64 * 1024

// SESSION_STR_POOL_BYTES is the pool's whole capacity. See the header: it is
// fixed precisely so interned bytes never move, and exhausting it is an assert
// naming this constant.
SESSION_STR_POOL_BYTES :: 1 << 20

// Session_Str_Handle locates one interned string. A zero handle is the empty
// string, which is why offset 0 is reserved: byte 0 of the pool is never handed
// out, so a real string always has off > 0 and a zeroed Clip field is
// unambiguously "no name" rather than a string starting at byte 0.
Session_Str_Handle :: struct {
	off: i32,
	len: i32,
}

// session_str is the pool. data is a fixed block so aliases into it stay valid
// for the whole session; used is the bump pointer; interned indexes the pool's
// strings by handle so equal names share storage and the dedupe scan is a walk
// of a slice rather than a re-derivation of handles from the bytes.
session_str: struct {
	data:     [SESSION_STR_POOL_BYTES]u8,
	used:     i32,
	interned: [dynamic]Session_Str_Handle,
}

// session_str_reset empties the pool. Every handle issued before this is dead:
// reading one afterwards is a stale-offset bug, which session_str_view's bound
// assert exists to catch. The block itself is static storage, so there is
// nothing to free -- reset is just rewinding the bump pointer.
session_str_reset :: proc() {
	session_str.used = 0
	clear(&session_str.interned)
}

// session_str_bytes is how much of the pool is in use, for telemetry and the
// probe.
session_str_bytes :: proc() -> int {
	return int(session_str.used)
}

// session_str_capacity is the pool's fixed size, so telemetry can show how close
// a session runs to the assert.
session_str_capacity :: proc() -> int {
	return SESSION_STR_POOL_BYTES
}

// session_str_count is how many distinct strings this session has interned.
session_str_count :: proc() -> int {
	return len(session_str.interned)
}

// session_str_view returns the interned string as a borrowed view. The result
// aliases the pool and stays valid until session_str_reset -- that is what the
// fixed block buys. Never written through: interning only ever bumps `used`, so
// published bytes are immutable and a rename cannot reach an existing holder.
// Clone it only if it must outlive the session.
session_str_view :: proc(h: Session_Str_Handle) -> string {
	if h.len <= 0 {
		assert(h.off == 0, "a session string handle has a length but no offset")
		return ""
	}
	assert(
		h.off > 0 && h.off + h.len <= session_str.used,
		"session string handle is stale or out of range: the pool was reset or overflowed under it",
	)
	// Zero-copy: the bytes are immutable and the block never moves, so aliasing is
	// safe, and it is the point -- a read site must not allocate.
	return string(session_str.data[h.off:h.off + h.len])
}

// session_str_intern copies s into the pool and returns its handle. Equal
// strings share storage, so duplicating a clip onto a new track costs no second
// copy of its name. Runs on import, rename and track creation -- never on a
// read -- so the dedupe scan below costs per user action, not per frame.
session_str_intern :: proc(s: string) -> Session_Str_Handle {
	if len(s) == 0 {
		return {}
	}
	assert(
		len(s) <= SESSION_STR_MAX_LEN,
		"interned string exceeds SESSION_STR_MAX_LEN: something interned a buffer, not a name",
	)
	for h in session_str.interned {
		if h.len == i32(len(s)) && string(session_str.data[h.off:h.off + h.len]) == s {
			return h
		}
	}
	// Reserve byte 0 so the empty handle stays distinguishable from a string that
	// happens to start at the first byte.
	if session_str.used == 0 {
		session_str.used = 1
	}
	off := session_str.used
	assert(
		off + i32(len(s)) <= i32(SESSION_STR_POOL_BYTES),
		"the session string pool is full: raise SESSION_STR_POOL_BYTES in session_str.odin",
	)
	copy(session_str.data[off:off + i32(len(s))], s)
	session_str.used = off + i32(len(s))
	h := Session_Str_Handle{off, i32(len(s))}
	append(&session_str.interned, h)
	return h
}

// ---------------------------------------------------------------------------
// Accessors. Every read of an interned string goes through one of these, so a
// read site cannot accidentally allocate, mutate the pool, or hand out a
// writable view. Clip and Clip_Marker carry the handle; the pool owns the bytes.
// ---------------------------------------------------------------------------

// clip_name is the clip's label. The result borrows the pool.
clip_name :: proc(c: ^Clip) -> string {
	return session_str_view(c.name)
}

// clip_set_name republishes the clip's label. The previous name's bytes stay
// put and every other holder of that handle keeps reading them -- a rename
// cannot be observed by anyone but this clip, which is why no site needs to
// copy the old string out first.
clip_set_name :: proc(c: ^Clip, s: string) {
	c.name = session_str_intern(s)
}

// marker_label is a marker's text. The result borrows the pool.
marker_label :: proc(m: ^Clip_Marker) -> string {
	return session_str_view(m.label)
}

marker_set_label :: proc(m: ^Clip_Marker, s: string) {
	m.label = session_str_intern(s)
}
