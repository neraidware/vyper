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
		session_trk_push(&source, Keyframe_Track{name=session_str_intern("probe"), lanes=make([dynamic]Keyframe_Lane, 1, 1)})
		session_trk_view_mut(&source, 0).lanes[0] = lane
		copy := session_trk_share(&source)
		session_trk_check(source.shared && copy.shared && source.first == copy.first,
			"copy shares initial track span")
		copy_track := session_trk_view_mut(&copy, 0)
		session_trk_check(copy.first != source.first && !copy.shared,
			"first write clones track rows only")
		// The lane array is part of the cloned row, and the key range inside it is
		// marked shared, so the source and the copy still address one key array
		// until one of them writes.
		session_trk_check(
			keyframe_lane_view(session_trk_view(source, 0), 0).shared &&
			keyframe_lane_view(copy_track, 0).shared,
			"track clone marks key ranges shared")
		copy_lane := copy_track.lanes[0].keys
		session_kf_make_unique(&copy_lane)
		session_kf_at_ptr(copy_lane, 0).value = 9.0
		copy_track.lanes[0].keys = copy_lane
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
