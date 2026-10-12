package vyper

import "core:fmt"
import "core:os"

session_lane_failures: int

// session_lane_check is the lane store's assertion, worded with the lane index
// and count so a failure says WHICH lane of which track shape went wrong. It
// records and continues like session_kf_probe's: one run should report every
// broken invariant, not just the first, or debugging costs a rebuild per try.
session_lane_check :: proc(condition: bool, format: string, args: ..any) {
	if condition {
		return
	}
	fmt.eprintf("session_lane probe failed: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	session_lane_failures += 1
}

// session_lane_probe_run is the env-gated entry (VYPER_SESSION_LANE_PROBE),
// matching session_kf_probe_run.
session_lane_probe_run :: proc() {
	os.exit(session_lane_probe_main())
}

// session_lane_probe exercises the lane store directly, the way
// session_kf_probe exercises the key store: the store is a session arena with a
// free list, a growth path and copy-on-write, and each of those is a way to leak
// or to alias. The probe pins the three properties the rest of the keyframe
// system relies on and cannot see from a clip:
//
//  1. a freed lane window's slots are reused, so ripple editing a lane for hours
//     does not grow the store a range per delete;
//  2. growth past a stranded span relocates and copies intact;
//  3. copy-on-write separates a cloned window before a write, and the write is
//     visible only through the writer.
session_lane_probe_main :: proc() -> int {
	// --- a push builds a window with the lanes it was given, in order ---------
	{
		r := Keyframe_Lanes_Range{}
		for lane in 0 ..< 3 {
			keys := Keyframe_Keys_Range{}
			session_kf_push(&keys, Keyframe{frame_off = i32(lane), value = f32(lane)})
			session_lane_push(&r, Keyframe_Lane{keys = keys})
		}
		session_lane_check(r.n == 3, "3 pushes gave %d lanes, want 3", r.n)
		view := session_lane_view(r)
		for lane in 0 ..< 3 {
			session_lane_check(
				view[lane].keys.n == 1 && session_kf_at(view[lane].keys, 0).value == f32(lane),
				"lane %d did not survive the push (n=%d)",
				lane,
				view[lane].keys.n,
			)
		}
		// The win is the reason this store exists, so it is pinned rather than
		// remembered: a track row was 272 bytes (an inline [Keyframe_Lane_Max] of
		// 32-byte lanes) and is now 40. Re-inlining the lanes would pass every
		// behavioural check below and quietly give the 232 bytes back, which is
		// exactly the regression nothing else here would catch.
		session_lane_check(
			size_of(Keyframe_Track) <= 48,
			"a track row is %d bytes; the inline lane array is back",
			size_of(Keyframe_Track),
		)
		// The bound is an assert, not storage: pushing past it must fail loudly
		// rather than truncate a curve.
		session_lane_check(
			Keyframe_Lane_Max == 4,
			"lane bound is %d; keyframe_geom_sections' widest section (crop) is 4",
			Keyframe_Lane_Max,
		)
		session_lane_release(r)
	}

	// --- erase SLIDES, so a keyed section keeps its lane indices ------------
	// crop.l / crop.r / crop.t / crop.b are four lanes, and lane i is the
	// section's lane i. Removing crop.r must leave crop.t at index 2, not slide
	// it to 1 -- otherwise crop.t's curve renders as crop.r. An inline array made
	// this a per-lane copy; a window makes it one mem.copy, and the probe pins
	// the behaviour rather than the cost.
	{
		r := Keyframe_Lanes_Range{}
		for lane in 0 ..< 4 {
			keys := Keyframe_Keys_Range{}
			session_kf_push(&keys, Keyframe{frame_off = 10, value = f32(lane)})
			session_lane_push(&r, Keyframe_Lane{keys = keys})
		}
		session_lane_erase(&r, 1)
		view := session_lane_view(r)
		session_lane_check(r.n == 3, "erase left %d lanes, want 3", r.n)
		session_lane_check(
			view[2].keys.n == 1 && session_kf_at(view[2].keys, 0).value == 3.0,
			"erase did not slide: lane 2 should now be the old lane 3 (value 3), got %d keys",
			view[2].keys.n,
		)
		session_lane_release(r)
	}

	// --- freed space is REUSED, not leaked past the bound -------------------
	// The same reason session_kf_probe runs 500 rounds: a bump pointer would
	// grow the store by a full window per delete, and ripple editing deletes
	// lanes for hours.
	{
		session_lane_reset()
		peak_rows := len(session_lane_rows)
		for round in 0 ..< 500 {
			r := Keyframe_Lanes_Range{}
			for lane in 0 ..< 4 {
				keys := Keyframe_Keys_Range{}
				session_kf_push(&keys, Keyframe{frame_off = i32(lane), value = f32(round)})
				session_lane_push(&r, Keyframe_Lane{keys = keys})
			}
			session_lane_check(
				session_kf_at(session_lane_view(r)[3].keys, 0).value == f32(round),
				"round %d: lane 3 did not survive reuse",
				round,
			)
			for lane in 0 ..< r.n {
				session_kf_release(session_lane_view(r)[lane].keys)
			}
			session_lane_release(r)
		}
		session_lane_check(
			session_lane_live == 0,
			"500 alloc/free rounds left %d live lane slots, want 0",
			session_lane_live,
		)
		session_lane_check(
			session_lane_live_peak <= SESSION_LANE_MIN_CAP + 4,
			"live peak grew to %d: freed lane slots are not being reused",
			session_lane_live_peak,
		)
		session_lane_check(
			len(session_lane_rows) <= peak_rows + 4,
			"lane store grew to %d slots after reuse rounds (was %d): the free list is not being hit",
			len(session_lane_rows),
			peak_rows,
		)
		session_lane_check(
			len(session_lane_free_spans) <= 1,
			"500 freed rounds left %d separate spans; coalescing is not merging",
			len(session_lane_free_spans),
		)
	}

	// --- growth past a STRANDED range relocates, and the copy is intact -----
	// A window that cannot grow in place (the span after it is live) must
	// allocate, copy and free. The move is the one case that invalidates a
	// borrowed view, so the probe checks the data arrived and the mover moved.
	{
		session_lane_reset()
		stranded := Keyframe_Lanes_Range{}
		for lane in 0 ..< 2 {
			keys := Keyframe_Keys_Range{}
			session_kf_push(&keys, Keyframe{frame_off = 0, value = f32(lane)})
			session_lane_push(&stranded, Keyframe_Lane{keys = keys})
		}
		front := Keyframe_Lanes_Range{}
		before := len(session_lane_rows)
		for lane in 0 ..< 8 {
			keys := Keyframe_Keys_Range{}
			session_kf_push(&keys, Keyframe{frame_off = i32(lane), value = 7.0})
			session_lane_push(&front, Keyframe_Lane{keys = keys})
		}
		session_lane_check(front.n == 8, "growth to 8 lanes gave %d", front.n)
		session_lane_check(
			len(session_lane_rows) > before,
			"growth past a stranded window did not grow the store",
		)
		view := session_lane_view(front)
		for lane in 0 ..< 8 {
			session_lane_check(
				view[lane].keys.n == 1 && session_kf_at(view[lane].keys, 0).value == 7.0,
				"relocated lane %d lost its key in the copy",
				lane,
			)
		}
		session_lane_check(
			stranded.n == 2 && session_lane_view(stranded)[1].keys.n == 1,
			"growing past a stranded window corrupted it",
		)
		session_lane_reset()
	}

	// --- copy-on-write separates the window before a write ------------------
	// A cloned track shares its lane window. A write through the accessor must
	// clone the window first, so the clone's write is invisible to the source --
	// this is the step ABOVE key COW, and it is the new one: before the lanes were
	// inline, a struct copy of the row copied them for free.
	{
		session_lane_reset()
		source := Keyframe_Lanes_Range{}
		for lane in 0 ..< 2 {
			keys := Keyframe_Keys_Range{}
			session_kf_push(&keys, Keyframe{frame_off = 10, value = 1.0})
			session_lane_push(&source, Keyframe_Lane{keys = keys})
		}
		// Sharing is the shared bit, not a copy: a copied track hands its holder the
		// same range handle. This is the exact sequence session_trk_clone_range runs,
		// including marking the key ranges inside shared, because a write that
		// reaches the keys without that would edit both holders.
		source.shared = true
		for lane in 0 ..< source.n {
			session_lane_view(source)[lane].keys.shared = true
		}
		clone := source
		clone.shared = true
		session_lane_check(
			source.shared && clone.shared && source.first == clone.first,
			"a shared handle must address the source window",
		)

		live_before_split := session_lane_live
		session_lane_make_unique(&clone)
		session_lane_check(!clone.shared, "make_unique left the clone shared")
		session_lane_check(
			source.shared && clone.first != source.first,
			"make_unique did not relocate the clone off the shared window",
		)
		// Splitting allocates the clone's window and does NOT free the shared one:
		// the source still addresses it. A make_unique that freed here would be the
		// double-free this store exists to get right, and live counts it exactly.
		session_lane_check(
			session_lane_live == live_before_split + clone.slots,
			"splitting a shared window left %d live slots, want %d (it freed or leaked the shared one)",
			session_lane_live,
			live_before_split + clone.slots,
		)
		// Write through the now-unique clone.
		clone_keys := session_lane_at_ptr(clone, 0).keys
		session_kf_make_unique(&clone_keys)
		session_kf_at_ptr(clone_keys, 0).value = 9.0
		session_lane_at_ptr(clone, 0).keys = clone_keys
		session_lane_check(
			session_kf_at(session_lane_view(source)[0].keys, 0).value == 1.0,
			"writing the clone changed the source: window COW did not separate",
		)
		session_lane_check(
			session_kf_at(session_lane_view(clone)[0].keys, 0).value == 9.0,
			"the clone's write did not land",
		)
		// The source still marks itself shared, so ITS release must not free a
		// window the clone is now using.
		session_lane_release(source)
		session_lane_check(
			session_lane_at(clone, 1).keys.n == 1,
			"releasing the shared source freed the clone's window",
		)
		session_lane_check(
			session_lane_live == live_before_split + clone.slots,
			"releasing a shared window freed %d slots it does not own",
			live_before_split + clone.slots - session_lane_live,
		)
		session_lane_release(clone)
		// Releasing the clone's own window returns the store to exactly the shared
		// window and nothing else: no split leak, no double free.
		session_lane_check(
			session_lane_live == live_before_split,
			"releasing the clone left %d live slots, want the shared window's %d",
			session_lane_live,
			live_before_split,
		)
		session_lane_reset()
		session_kf_reset()
	}

	// --- an erased LAST lane does not slide a one-past-the-end pointer ------
	// The shape that crashed the app: mem.copy over an empty tail still evaluates
	// its source pointer, and a one-past-the-end pointer on the store is an index
	// error even with nothing to copy. Fixed in the lane store, and pinned here
	// because it is the same bug the track and marker stores hit.
	{
		r := Keyframe_Lanes_Range{}
		keys := Keyframe_Keys_Range{}
		session_kf_push(&keys, Keyframe{frame_off = 5, value = 1.0})
		session_lane_push(&r, Keyframe_Lane{keys = keys})
		session_lane_erase(&r, 0)
		session_lane_check(r.n == 0, "erasing the last lane left %d lanes", r.n)
		session_kf_release(keys)
		session_lane_release(r)
	}

	// --- release is a no-op on a shared or empty window ---------------------
	{
		shared := Keyframe_Lanes_Range{}
		keys := Keyframe_Keys_Range{}
		session_kf_push(&keys, Keyframe{frame_off = 1, value = 1.0})
		session_lane_push(&shared, Keyframe_Lane{keys = keys})
		shared.shared = true
		live_before := session_lane_live
		session_lane_release(shared)
		session_lane_check(
			session_lane_live == live_before,
			"releasing a shared window freed %d slots",
			live_before - session_lane_live,
		)
		shared.shared = false
		session_lane_release(shared)
		session_kf_release(keys)
		session_lane_check(
			session_lane_live == 0,
			"the store leaked %d slots after the shared-release check",
			session_lane_live,
		)
		session_lane_reset()
	}

	return session_lane_failures
}