// session_kf_probe: the session key store's allocator and COW invariants
// (TODO.md Active 19, S2b). Registered as `scripts/gate.sh session_kf_probe`.
//
// The store is the one place in the clip POD work that MOVES memory, so this
// probe is about the properties that movement can break: a range survives being
// written through, sharing is resolved on write and only on write, freed space
// is actually reused, and a stale handle after a reset fails loudly instead of
// reading another range's keys.
package vyper

import "core:fmt"
import "core:os"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

	session_kf_failures: int

	session_kf_check :: proc(cond: bool, msg: string, args: ..any) {
		if cond {
			return
		}
		session_kf_failures += 1
		fmt.eprintf("[session-kf-probe] FAIL: ")
		fmt.eprintf(msg, ..args)
		fmt.eprintln()
	}

	// kf_key builds a scalar key at a frame, so the checks below read as key data
	// rather than as struct literals.
	session_kf_key :: proc(frame: i32, v: f32) -> Keyframe {
		return Keyframe{frame_off = frame, value = v}
	}

	// session_kf_probe_run is the env-gated entry (VYPER_SESSION_KF_PROBE), matching
	// the other probes: same binary, no second main.
	session_kf_probe_run :: proc() {
		os.exit(session_kf_probe_main())
	}

	// session_kf_probe_main runs the probe and returns the process exit code.
	session_kf_probe_main :: proc() -> int {
		session_kf_reset()

		// --- a range round-trips its keys -------------------------------------
		{
			r := Kf_Keys_Range{}
			session_kf_reserve(&r, 3)
			for i in 0 ..< 3 {
				session_kf_push(&r, session_kf_key(i32(i) * 10, f32(i)))
			}
			got := session_kf_view(r)
			session_kf_check(r.n == 3, "n=%d, want 3", r.n)
			session_kf_check(
				got[0].frame_off == 0 && got[1].frame_off == 10 && got[2].frame_off == 20,
				"keys did not round-trip: %v %v %v",
				got[0].frame_off,
				got[1].frame_off,
				got[2].frame_off,
			)
			session_kf_check(got[1].value.(f32) == 1.0, "value[1]=%v, want 1", got[1].value)
		}

		// --- growth is AMORTIZED, not per-insert --------------------------------
		// The property that justifies the capacity slack. With no slack, every
		// insert reallocates and copies the whole range, which is O(n) on the auto-
		// key path -- a drag inserting one key per frame would be quadratic. Doubling
		// bounds the relocations for N inserts at log2(N), and the count is
		// asserted so a regression to per-insert copying fails here.
		//
		// NOTE this is NOT the same as "grows in place". A range sitting at the tail
		// of the store has no free span after it to eat, so it relocates; the
		// in-place path only fires when a free span follows. Both are checked below,
		// because they are different properties.
		{
			before := session_kf_moves
			r := Kf_Keys_Range{}
			session_kf_reserve(&r, 1)
			for i in 0 ..< 40 {
				session_kf_push(&r, session_kf_key(i32(i), f32(i)))
			}
			moves := session_kf_moves - before
			// 1 -> 8 -> 16 -> 32 -> 64 for 40 inserts. Allow slack for a different
			// growth policy, but not for per-insert copying (which would be 40).
			session_kf_check(moves <= 8, "40 inserts caused %d relocations, want <= 8", moves)
			session_kf_check(r.n == 40, "n=%d, want 40", r.n)
			got := session_kf_view(r)
			ok := true
			for i in 0 ..< 40 {
				if got[i].frame_off != i32(i) || got[i].value.(f32) != f32(i) {
					ok = false
					break
				}
			}
			session_kf_check(ok, "a key was lost or reordered across %d relocations", moves)
			session_kf_release(r)
		}

		// --- growth IS in place when a free span follows ------------------------
		// The case that keeps borrowed views alive and costs no copy at all: a range
		// with room to spare immediately after it extends itself. Stranding that
		// free span is what forces the relocation checked above, so the two tests
		// together cover both arms of session_kf_grow.
		{
			session_kf_reset()
			a := Kf_Keys_Range{}
			session_kf_reserve(&a, 8) // lands at the tail, slots=8
			// Allocate a neighbour directly after, then free it: that leaves a free
			// span starting exactly at a.first + a.slots.
			blocker := Kf_Keys_Range{}
			session_kf_reserve(&blocker, 8)
			session_kf_release(blocker)
			first_addr := uintptr(raw_data(session_kf_keys[a.first :]))
			before := session_kf_moves
			// Doubling, not to-the-exact-need: 8 slots asked for 12 grows to 16, and
			// the 4 extra slots of headroom is what keeps the next few inserts from
			// moving the range again.
			session_kf_reserve(&a, 12)
			now_addr := uintptr(raw_data(session_kf_keys[a.first :]))
			session_kf_check(
				a.first == 0 && a.slots == 16,
				"in-place growth gave first=%d slots=%d, want first=0 slots=16",
				a.first,
				a.slots,
			)
			session_kf_check(now_addr == first_addr, "in-place growth moved the range")
			session_kf_check(
				session_kf_moves == before,
				"in-place growth counted a relocation",
			)
			session_kf_release(a)
		}

		// --- COW: two holders, a write through one is invisible to the other ----
		// The invariant that lets a Clip copy be a struct copy. Without it,
		// duplicating a clip and then editing one half would silently edit both.
		{
			// Force the COW allocation to grow the global key backing. A view taken
			// before this allocation would point into the old block after realloc.
			session_kf_reset()
			delete(session_kf_keys)
			session_kf_keys = nil
			a := Kf_Keys_Range{}
			session_kf_reserve(&a, 2)
			session_kf_push(&a, session_kf_key(5, 50.0))
			session_kf_push(&a, session_kf_key(15, 150.0))

			// A copy shares until someone writes: same slots, marked shared.
			b := a
			b.shared = true
			a.shared = true

			session_kf_make_unique(&b)
			session_kf_check(!b.shared, "make_unique left b shared")
			session_kf_check(b.first != a.first, "make_unique did not move the shared range")
			session_kf_set(&b, 0, session_kf_key(5, 999.0))
			session_kf_check(b.first != a.first, "b and a still alias after the write")
			av := session_kf_view(a)
			session_kf_check(
				av[0].value.(f32) == 50.0,
				"writing the shared copy changed the original: a[0]=%v, want 50",
				av[0].value,
			)

			// make_unique on an already-unique range is a no-op, so a second edit
			// does not pay for another copy.
			slot_before := b.first
			session_kf_make_unique(&b)
			session_kf_check(b.first == slot_before, "make_unique copied a unique range")

			session_kf_release(a)
			session_kf_release(b)
		}

		// --- the shared bit survives a struct copy -----------------------------
		// A Clip copy is `src^`, which copies this bit verbatim. If the bit did not
		// travel, the second holder would think it owns the range and write through
		// it; that failure is invisible in the type, so it is pinned here.
		{
			shared := Kf_Keys_Range{first = 0, slots = 1, n = 0, shared = true}
			copied := shared
			session_kf_check(copied.shared, "a struct copy dropped the shared bit")
			// The other half of the guard: session_kf_view_mut refuses a shared
			// range, which is what stops a future write site from corrupting a copy.
			// Exercising the assert needs a subprocess, so the mutation that proves
			// it fires is recorded in TODO.md Active 19 S2b rather than run here.
		}

		// --- freed space is REUSED, not leaked past the bound -------------------
		// The reason this file has an allocator at all: a bump pointer would grow
		// the store by a full range per delete, and ripple-editing deletes keys for
		// hours. Allocate and free the same shape many times; the live count, the
		// array's high-water mark and the span count must all stay flat.
		{
			session_kf_reset()
			peak_keys := len(session_kf_keys)
			for round in 0 ..< 500 {
				r := Kf_Keys_Range{}
				session_kf_reserve(&r, 16)
				for i in 0 ..< 16 {
					session_kf_push(&r, session_kf_key(i32(round), f32(i)))
				}
				session_kf_check(
					session_kf_view(r)[3].value.(f32) == 3.0,
					"round %d: keys did not survive reuse",
					round,
				)
				session_kf_release(r)
			}
			session_kf_check(
				session_kf_live == 0,
				"500 alloc/free rounds left %d live slots, want 0",
				session_kf_live,
			)
			session_kf_check(
				session_kf_live_peak <= SESSION_KF_MIN_CAP + 16,
				"live peak grew to %d: freed slots are not being reused",
				session_kf_live_peak,
			)
			session_kf_check(
				len(session_kf_keys) <= peak_keys + 16,
				"store grew to %d slots after reuse rounds (was %d): the free list is not being hit",
				len(session_kf_keys),
				peak_keys,
			)
			session_kf_check(
				len(session_kf_free_spans) <= 1,
				"500 freed rounds left %d separate spans; coalescing is not merging",
				len(session_kf_free_spans),
			)
		}

		// --- growth past a stranded range relocates, and the copy is intact -----
		{
			session_kf_reset()
			a := Kf_Keys_Range{}
			session_kf_reserve(&a, 2)
			session_kf_push(&a, session_kf_key(1, 10.0))
			session_kf_push(&a, session_kf_key(2, 20.0))
			// Strand a range right after `a` so there is no free span to extend
			// into; the next growth has to move.
			blocker := Kf_Keys_Range{}
			session_kf_reserve(&blocker, 2)
			before_moves := session_kf_moves
			session_kf_reserve(&a, 64)
			session_kf_check(
				session_kf_moves == before_moves + 1,
				"growth past a stranded range should relocate once, moves went %d -> %d",
				before_moves,
				session_kf_moves,
			)
			av := session_kf_view(a)
			session_kf_check(
				a.n == 2 && av[0].frame_off == 1 && av[1].frame_off == 2,
				"relocation lost or corrupted keys",
			)
			session_kf_release(a)
			session_kf_release(blocker)
		}

		// --- coalescing MERGES ADJACENT frees ------------------------------------
		// The reuse loop above frees the same range every round, so it never needs
		// coalescing and cannot prove it works. Without merging, a session that
		// frees neighbouring ranges ends up with thousands of one-slot spans that
		// nothing can use, and the store grows past its bound while reporting itself
		// half empty. So free two adjacent ranges -- second first, which is the order
		// that puts the new span BETWEEN two live entries in the sorted list.
		{
			session_kf_reset()
			a := Kf_Keys_Range{}
			session_kf_reserve(&a, 8)
			b := Kf_Keys_Range{}
			session_kf_reserve(&b, 8)
			session_kf_check(
				a.first + a.slots == b.first,
				"fixture: the two ranges are not adjacent (%d+%d vs %d)",
				a.first,
				a.slots,
				b.first,
			)
			session_kf_release(b)
			session_kf_check(
				len(session_kf_free_spans) == 1,
				"one free should leave 1 span, got %d",
				len(session_kf_free_spans),
			)
			session_kf_release(a)
			session_kf_check(
				len(session_kf_free_spans) == 1,
				"two ADJACENT frees must coalesce into 1 span, got %d",
				len(session_kf_free_spans),
			)
			session_kf_check(
				session_kf_free_spans[0].cap == 16,
				"the coalesced span should be 16 slots, got %d",
				session_kf_free_spans[0].cap,
			)
			// And the merged span must actually serve a request for its full width,
			// which is the point of merging it.
			c := Kf_Keys_Range{}
			session_kf_reserve(&c, 16)
			session_kf_check(
				c.first == a.first,
				"the merged span did not serve a 16-slot request (first=%d)",
				c.first,
			)
			session_kf_check(
				len(session_kf_keys) == 16,
				"a 16-slot request should not have grown the store, len=%d",
				len(session_kf_keys),
			)
			session_kf_release(c)
		}

		// --- a zero-value range is empty and safe (the useful zero value) -------
		{
			session_kf_reset()
			z := Kf_Keys_Range{}
			session_kf_check(z.n == 0 && z.slots == 0, "the zero range is not empty")
			session_kf_check(len(session_kf_view(z)) == 0, "the zero range does not view as empty")
			session_kf_check(!z.shared, "the zero range claims to be shared")
			session_kf_release(z) // freeing the empty range is a no-op, not a crash
		}

		// --- reset invalidates every handle, and the read side says so ---------
		// A stale handle must fail LOUDLY. Silent reuse would hand one clip another
		// clip's keys, which is the exact corruption S0's assert was chosen to
		// prevent.
		{
			session_kf_reset()
			r := Kf_Keys_Range{}
			session_kf_reserve(&r, 4)
			session_kf_push(&r, session_kf_key(7, 70.0))
			stale := r
			session_kf_reset()
			session_kf_check(
				stale.n == 1 && len(session_kf_keys) == 0,
				"reset did not rewind: n=%d, store=%d slots",
				stale.n,
				len(session_kf_keys),
			)
			// session_kf_view's bounds assert is what catches a stale handle.
			// Verifying an assert fires needs a subprocess, so what is asserted here
			// is the precondition the assert reads: the handle is now out of bounds,
			// so the assert's condition is false.
			session_kf_check(
				stale.first + stale.slots > len(session_kf_keys),
				"a post-reset handle is still in bounds; the assert could not catch it",
			)
		}

		if session_kf_failures > 0 {
			fmt.eprintf("[session-kf-probe] %d check(s) FAILED\n", session_kf_failures)
			return 1
		}
		fmt.eprintln("[session-kf-probe] PASS")
		fmt.eprintln(
			"[session-kf-probe] growth amortized over 40 inserts and in place when a free span follows, COW resolved on write only, 500 alloc/free rounds reused down to one coalesced span, one relocation copying keys intact, and reset leaving every handle out of bounds",
		)
		fmt.eprintln(
			"[session-kf-probe] bounds named: SESSION_KF_MAX_KEYS, SESSION_KF_MIN_CAP",
		)
		return 0
	}

}
