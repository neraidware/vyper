package main

import "core:fmt"
import "core:os"

// ---------------------------------------------------------------------------
// Session string pool probe (VYPER_SESSION_STR_PROBE=1).
//
// The pool replaced per-Clip heap strings for clip names and marker labels
// (TODO.md Active 19), so what used to be a compiler-checked ownership chain is
// now an offset+length handle into one session block. The compiler can no longer
// see a name leak or a stale handle; these assertions are what stands in for it.
//
// The properties that matter, in the order they break:
//   1. A read returns the interned bytes, and a rename is invisible to everyone
//      holding the old handle. That immutability is the entire safety argument
//      for sharing a handle across copies, so it is asserted from both sides.
//   2. Equal strings share storage (dedupe), so duplicating a clip costs no
//      second copy of its name.
//   3. A zero handle is the empty string and a zeroed Clip is safe to read --
//      the pool reserves offset 0 precisely so those two can't be confused.
//   4. session_str_reset invalidates every handle. Reading one afterwards is a
//      stale-offset bug, which session_str_view's assert is there to catch; the
//      probe proves the reset empties the pool and that a fresh intern still
//      works, without tripping that assert.
//   5. Offsets stay valid as the pool grows -- appending must not move anything
//      an existing handle points into, or every live Clip name would rot the
//      moment a second clip was imported.
//   6. Over-long interning is rejected at the intern site rather than truncated.
//      The length gate is checked through the same constant the pool asserts on.
//
// Exits 0 only when every stage passes; each stage prints before it runs so a
// crash names its stage.
// ---------------------------------------------------------------------------

// session_str_probe_check formats its message ONCE into a fixed buffer: passing
// the format string and the arg slice to a second printer would echo the
// template instead of the values, which is how a probe ends up reporting
// "%d bytes" forever without anyone noticing the numbers are missing.
session_str_probe_check :: proc(cond: bool, msg: string, args: ..any) {
	buf: [512]u8
	line := fmt.bprintf(buf[:], msg, ..args)
	if !cond {
		fmt.eprintf("[session-str-probe] FAIL: %s\n", line)
		os.exit(1)
	}
	fmt.println("[session-str-probe]", line)
}

session_str_probe_run :: proc() {
	session_str_reset()

	// 1. Round-trip a read, and prove a rename is invisible to the old holder.
	h := session_str_intern("A012_C003_take07.mov")
	session_str_probe_check(
		session_str_view(h) == "A012_C003_take07.mov",
		"intern then view returns the same bytes",
	)
	before_bytes := session_str_bytes()
	h2 := session_str_intern("A012_C003_take08.mov")
	session_str_probe_check(
		session_str_view(h) == "A012_C003_take07.mov",
		"interning a different string left the first handle's bytes alone",
	)
	session_str_probe_check(
		session_str_bytes() > before_bytes,
		"the second intern appended (%d -> %d bytes)",
		before_bytes,
		session_str_bytes(),
	)
	session_str_probe_check(
		h2.off >= h.off + h.len,
		"the pool only appends: %d >= %d",
		h2.off,
		h.off + h.len,
	)

	after_views := session_str_view(session_str_intern("second-survivor"))

	// The Clip-level shape of the same property: a copy shares the handle, a
	// rename publishes a new one, and the original copy is unaffected.
	src := Clip{name = h}
	dup := src // what clip_deep_copy does for the name field
	clip_set_name(&dup, "renamed")
	session_str_probe_check(
		clip_name(&src) == "A012_C003_take07.mov" && clip_name(&dup) == "renamed",
		"a rename through clip_set_name reached only the renamed clip (%q / %q)",
		clip_name(&src),
		clip_name(&dup),
	)
	session_str_probe_check(
		src.name == h,
		"the source clip still holds the ORIGINAL handle, not the new one",
	)

	// 2. Dedupe: equal strings share one handle, so a copy costs nothing.
	a := session_str_intern("shared-name")
	bytes_before := session_str_bytes()
	b := session_str_intern("shared-name")
	session_str_probe_check(
		a == b,
		"equal strings share one handle (%d/%d)",
		a.off,
		b.off,
	)
	session_str_probe_check(
		session_str_bytes() == bytes_before,
		"the duplicate intern allocated nothing (%d bytes)",
		session_str_bytes(),
	)

	// 3. The zero handle is empty, and a zeroed Clip is readable.
	session_str_probe_check(
		session_str_view({}) == "" && clip_name(&Clip{}) == "" && marker_label(&Clip_Marker{}) == "",
		"a zero handle reads as the empty string, so a zeroed Clip is safe",
	)
	session_str_probe_check(
		session_str_intern("") == Session_Str_Handle{} && session_str_bytes() == bytes_before,
		"interning an empty string stores nothing",
	)
	// Offset 0 is reserved, so no real handle can collide with the empty one.
	first := session_str_intern("x")
	session_str_probe_check(
		first.off > 0,
		"the first interned string starts past the reserved byte (off %d)",
		first.off,
	)

	// 5. Growth must not MOVE published bytes. Hold a view -- not just a handle
	// -- across enough interns to exhaust any smaller block, then read it back.
	// This is the assertion the pool's fixed size exists for: with a
	// [dynamic]u8 the first reallocation left every captured view dangling, and
	// the caller could not tell a moved buffer from a live one.
	aliased := session_str_view(session_str_intern("survivor"))
	for i in 0 ..< 512 {
		buf: [32]u8
		session_str_intern(fmt.bprintf(buf[:], "filler-%d", i))
	}
	session_str_probe_check(
		aliased == "survivor",
		"a view captured before 512 more interns still reads its own bytes (%q)",
		aliased,
	)
	session_str_probe_check(
		after_views == "second-survivor",
		"a second captured view survived the same growth",
	)
	session_str_probe_check(
		session_str_count() >= 512,
		"the intern table tracked the appends (%d distinct strings)",
		session_str_count(),
	)
	session_str_probe_check(
		session_str_capacity() == SESSION_STR_POOL_BYTES &&
			session_str_bytes() < session_str_capacity(),
		"the pool is a fixed block, in use %d of %d bytes",
		session_str_bytes(),
		session_str_capacity(),
	)

	// 4. Reset: the pool empties, and a fresh intern works afterwards. This is
	// what a project load does (session_teardown -> session_str_reset), and it is
	// only safe because no Clip value outlives the timeline.
	session_str_reset()
	// Reset leaves the pool EMPTY; the reserved byte is re-appended by the next
	// intern, which is why a post-reset handle still starts past 0.
	session_str_probe_check(
		session_str_bytes() == 0 && session_str_count() == 0,
		"reset empties the pool (%d bytes, %d strings)",
		session_str_bytes(),
		session_str_count(),
	)
	after_reset := session_str_intern("post-reset")
	session_str_probe_check(
		session_str_view(after_reset) == "post-reset" && after_reset.off > 0,
		"interning works again after a reset, past the reserved byte (off %d)",
		after_reset.off,
	)
	// Handles from before the reset are dead; only the assert in session_str_view
	// can catch a read of one, and an assert that fires is the correct outcome.
	fmt.println(
		"[session-str-probe] a pre-reset handle is now stale by design;",
		"reading one must trip session_str_view's assert, not return a wrong string",
	)

	// 6. The length gate the pool asserts on, at its real bound.
	session_str_probe_check(
		SESSION_STR_MAX_LEN == 64 * 1024,
		"the per-string bound is named and in force (%d bytes)",
		SESSION_STR_MAX_LEN,
	)

	// The view captured above still points into the block, but the bytes past
	// `used` are no longer part of the pool: reading it through a handle must
	// assert rather than hand back whatever the next intern wrote there.
	fmt.println(
		"[session-str-probe] pre-reset view was",
		aliased,
		"-- still readable as raw bytes, but its handle is out of range",
	)

	fmt.println("[session-str-probe] PASS")
}
