// Probe for POD clip-marker ranges, COW isolation and arena reuse.
package vyper

import "core:fmt"
import "core:os"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

	session_marker_failures: int

	session_marker_check :: proc(cond: bool, msg: string, args: ..any) {
		if cond { return }
		session_marker_failures += 1
		fmt.eprintf("[session-marker-probe] FAIL: ")
		fmt.eprintf(msg, ..args)
		fmt.eprintln()
	}

	session_marker_probe_run :: proc() {
		os.exit(session_marker_probe_main())
	}

	session_marker_probe_main :: proc() -> int {
		session_marker_reset()
		session_str_reset()
		session_marker_failures = 0

		source := Clip_Markers_Range{}
		session_marker_push(&source, Clip_Marker{source_frame=10, label=session_str_intern("original")})
		session_marker_push(&source, Clip_Marker{source_frame=20, label=session_str_intern("second")})
		copy := session_marker_share(&source)
		copy_marker := session_marker_at_mut(&copy, 0)
		marker_set_label(copy_marker, "copy-only")
		source_marker := session_marker_at(source, 0)
		copy_marker_value := session_marker_at(copy, 0)
		session_marker_check(copy.first != source.first && !copy.shared,
			"first marker write clones shared range")
		session_marker_check(marker_label(&source_marker) == "original" && marker_label(&copy_marker_value) == "copy-only",
			"renaming copy leaves source label intact")

		block := Clip_Markers_Range{}
		session_marker_push(&block, Clip_Marker{source_frame=30, label=session_str_intern("reusable")})
		off, slots := block.first, block.slots
		session_marker_release(block)
		reused := Clip_Markers_Range{}
		session_marker_push(&reused, Clip_Marker{source_frame=40, label=session_str_intern("reused")})
		session_marker_check(reused.first == off && reused.slots <= slots,
			"freed marker span reused (want %d, got %d)", off, reused.first)

		session_marker_reset()
		session_str_reset()
		if session_marker_failures > 0 {
			fmt.eprintf("[session-marker-probe] %d failures\n", session_marker_failures)
			return 1
		}
		fmt.eprintln("[session-marker-probe] PASS: marker COW isolation and range reuse")
		return 0
	}

}
