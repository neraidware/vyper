// Probe for session-owned keyframe track rows and track-then-key COW.
package vyper

import "core:fmt"
import "core:os"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

	session_trk_failures: int

	session_trk_check :: proc(cond: bool, msg: string, args: ..any) {
		if cond { return }
		session_trk_failures += 1
		fmt.eprintf("[session-trk-probe] FAIL: ")
		fmt.eprintf(msg, ..args)
		fmt.eprintln()
	}

	session_trk_probe_run :: proc() {
		os.exit(session_trk_probe_main())
	}

	session_trk_probe_main :: proc() -> int {
		session_trk_reset()
		session_kf_reset()
		session_trk_failures = 0

		// A copied Clip starts by sharing its track range. First track mutation
		// duplicates rows and marks key ranges shared; first key mutation then
		// duplicates key payload, leaving original untouched.
		lane := Keyframe_Lane{}
		session_kf_push(&lane.keys, Keyframe{frame_off=10, value=1.0})
		source := Keyframe_Track_Range{}
		session_trk_push(&source, Keyframe_Track{name=session_str_intern("probe")})
		session_lane_push(&session_trk_view_mut(&source, 0).lanes, lane)
		copy := session_trk_share(&source)
		session_trk_check(source.shared && copy.shared && source.first == copy.first,
			"copy shares initial track span")
		copy_track := session_trk_view_mut(&copy, 0)
		session_trk_check(copy.first != source.first && !copy.shared,
			"first write clones track rows only")
		// The lane WINDOW is part of the cloned row, and so is the key range inside
		// it: source and copy address one lane array and one key array until one of
		// them writes. Lane-window COW is the step above key COW, so the probe writes
		// through keyframe_lane_at_mut to exercise both.
		session_trk_check(
			keyframe_lane_view(session_trk_view(source, 0), 0).shared &&
			keyframe_lane_view(copy_track, 0).shared,
			"track clone marks key ranges shared")
		// The clip stands in for whatever holds the range, so the probe drives the
		// production door rather than a private path: it resolves the TRACK row and
		// then the LANE window, which is the step that did not exist when the lanes
		// were inline.
		holder: Clip
		holder.keyframe_tracks = copy
		copy_lane := keyframe_lane_at_mut(&holder, 0, 0).keys
		session_kf_make_unique(&copy_lane)
		session_kf_at_ptr(copy_lane, 0).value = 9.0
		keyframe_lane_at_mut(&holder, 0, 0).keys = copy_lane
		copy = holder.keyframe_tracks
		session_trk_check(
			session_kf_at(keyframe_lane_view(session_trk_view(source, 0), 0), 0).value == 1.0,
			"key COW preserves source value")
		session_trk_check(
			session_kf_at(keyframe_lane_view(copy_track, 0), 0).value == 9.0,
			"mutated copy gets independent key value")

		// Freed exclusive track blocks are reusable and coalesce; this keeps edits
		// from turning the session-lifetime arena into a bump-only allocation leak.
		block := Keyframe_Track_Range{}
		session_trk_push(&block, Keyframe_Track{})
		session_trk_push(&block, Keyframe_Track{})
		off, slots := block.first, block.slots
		session_trk_release_range(block)
		reused := Keyframe_Track_Range{}
		session_trk_push(&reused, Keyframe_Track{})
		session_trk_check(reused.first == off && reused.slots <= slots,
			"freed track block reused at %d (got %d)", off, reused.first)
		session_trk_release_range(reused)

		// Erasing or inserting at the END of a range that sits flush against the
		// end of the store. This is the crash: the slide has nothing to move, so its
		// length is 0 -- but `&rows[r.first+idx+1]` is evaluated regardless, and when
		// first+n == len(rows) that index is one past the array. Bounds-checked
		// builds abort on the pointer, not on the copy.
		//
		// Reachable from the editor: keyframe_drop_track calls session_trk_erase
		// whenever a track loses its last key, and the newest clip's range is
		// exactly the one occupying the tail of the store.
		//
		// The shape is a range that is FULL (n == slots) and ends at the array end.
		// A freshly reset store hands out SESSION_TRK_MIN_CAP slots at offset 0, so
		// filling it puts first+n == len(rows) without touching any field by hand.
		{
			session_trk_reset()
			session_kf_reset()

			tail := Keyframe_Track_Range{}
			for i in 0 ..< SESSION_TRK_MIN_CAP {
				session_trk_push(&tail, Keyframe_Track{name=session_str_intern("track")})
			}
			session_trk_check(
				tail.first + tail.n == len(session_trk_rows) && tail.n == tail.slots,
				"range must be full and flush at the array end (first=%d n=%d slots=%d rows=%d)",
				tail.first, tail.n, tail.slots, len(session_trk_rows))

			// Erase the LAST track: nothing to slide, and first+n is already len.
			session_trk_erase(&tail, tail.n - 1)
			session_trk_check(tail.n == SESSION_TRK_MIN_CAP-1,
				"erasing the last track of a flush range leaves n=%d (got %d)",
				SESSION_TRK_MIN_CAP-1, tail.n)
			// The survivors must be untouched: the guard skips a copy that has
			// nothing to move, not one that has.
			session_trk_check(session_trk_view(tail, 0).name == session_str_intern("track"),
				"the surviving first track is unchanged")
			session_trk_release_range(tail)

			// Insert at the END of a flush range: also nothing to slide.
			tail2 := Keyframe_Track_Range{}
			for i in 0 ..< SESSION_TRK_MIN_CAP {
				session_trk_push(&tail2, Keyframe_Track{name=session_str_intern("old")})
			}
			session_trk_insert(&tail2, tail2.n, Keyframe_Track{name=session_str_intern("new")})
			session_trk_check(
				tail2.n == SESSION_TRK_MIN_CAP+1 &&
				session_trk_view(tail2, tail2.n-1).name == session_str_intern("new"),
				"insert at the end appends (n=%d)", tail2.n)
			session_trk_release_range(tail2)

			// Erase from the MIDDLE: the case that actually shifts, so the guard
			// above is not hiding a broken slide.
			session_trk_reset()
			mid := Keyframe_Track_Range{}
			session_trk_push(&mid, Keyframe_Track{name=session_str_intern("p")})
			session_trk_push(&mid, Keyframe_Track{name=session_str_intern("q")})
			session_trk_push(&mid, Keyframe_Track{name=session_str_intern("r")})
			session_trk_erase(&mid, 1)
			session_trk_check(
				mid.n == 2 &&
				session_trk_view(mid, 0).name == session_str_intern("p") &&
				session_trk_view(mid, 1).name == session_str_intern("r"),
				"erasing the middle slides the tail (n=%d)", mid.n)
			session_trk_release_range(mid)
			session_trk_reset()
			session_kf_reset()
		}

		// Probe-created pool state dies here; production teardown owns normal reset.
		session_trk_reset()
		session_kf_reset()
		if session_trk_failures != 0 {
			fmt.eprintf("[session-trk-probe] %d failures\n", session_trk_failures)
			return 1
		}
		fmt.eprintln("[session-trk-probe] PASS: track spans reused; track COW precedes key COW")
		return 0
	}

}
