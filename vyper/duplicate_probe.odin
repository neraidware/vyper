package vyper

import "core:fmt"
import "core:os"
import "core:time"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

	duplicate_probe_fail := false

	dup_check :: proc(cond: bool, msg: string, args: ..any) {
		if !cond {
			duplicate_probe_fail = true
			fmt.printf("[dup-probe] FAIL: ")
			fmt.printf(msg, ..args)
			fmt.println()
		}
	}

	// duplicate_probe_run (VYPER_DUP_PROBE="<video file>"): reproduce
	// "a track-duplicated clip shows its bounding box but not its content", under
	// the two-array track model (tracks = storage, track_order = visual stack).
	//
	// Setup mirrors the real app: a video on storage track 0 with its audio on
	// track 1, duplicate_track(0), then check the copy landed ONE ROW ABOVE the
	// original in the visual stack (track_order), and both clips converge to
	// decoded preview slots while parked in the shared range.
	duplicate_probe_run :: proc(v: string) {
		editor_flags.async_import_mode = false
		inp: [4096]u8
		n := 0
		for n < len(v) && n < len(inp) - 1 {
			inp[n] = u8(v[n])
			n += 1
		}
		inp[n] = 0
		path := cstring(&inp[0])
		import_media(path)

		if len(timeline.tracks) == 0 || len(timeline.tracks[0].clips) == 0 {
			fmt.println("[dup-probe] no clip on track 0")
			os.exit(2)
		}
		orig_clip := &timeline.tracks[0].clips[0]
		orig_id := orig_clip.clip_id
		nc := orig_clip.source_length_frames
		fmt.println(
			"[dup-probe] imported tl=[",
			orig_clip.timeline_start_frame,
			",",
			orig_clip.timeline_start_frame + nc,
			") len=",
			nc,
		)

		duplicate_track(0)
		sync_track_order()
		dup_check(
			len(timeline.tracks) == 3 && len(timeline.track_order) == 3,
			"expected 3 tracks (orig video, orig audio, copy)",
		)
		orig_row := order_row_of(0)
		dup_check(
			orig_row == 1,
			"original must shift down one row (was 0, now %d)",
			orig_row,
		)
		dup_ti := track_at_row(orig_row - 1)
		dup_check(dup_ti >= 0 && dup_ti != 0, "a copy must sit in the row above the original")
		dup_ok := false
		dup_id: u64 = 0
		if dup_ti >= 0 && len(timeline.tracks[dup_ti].clips) > 0 {
			dup_id = timeline.tracks[dup_ti].clips[0].clip_id
			dup_ok = dup_id != orig_id
		}
		dup_check(dup_ok, "the row above the original must be a FRESH clip copy")
		for w := 0; w < len(timeline.track_order); w += 1 {
			ti := timeline.track_order[w]
			fmt.printf(
				"[dup-probe] row=%d storage=%d name=%q clips=%d\n",
				w,
				ti,
				timeline.tracks[ti].name,
				len(timeline.tracks[ti].clips),
			)
		}

		// Park mid-range; the top (duplicated) clip must converge to a decoded
		// slot -- that's the slot whose texture becomes the preview content.
		async_live_mode = true
		top_ok := false
		below_ok := false
		iter := 0
		for ; iter < 300; iter += 1 {
			playhead.frame = nc / 2
			update_preview_slots()
			top_ok = false
			below_ok = false
			for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
				if !preview_slots[s].in_use {
					continue
				}
				if preview_slots[s].clip_id == dup_id && preview_slots[s].has_frame {
					top_ok = true
				}
				if preview_slots[s].clip_id == orig_id && preview_slots[s].has_frame {
					below_ok = true
				}
			}
			if iter % 25 == 0 {
				fmt.printf(
					"[dup-probe] iter=%d top(dup)_has_frame=%v below(orig)_has_frame=%v\n",
					iter,
					top_ok,
					below_ok,
				)
			}
			if top_ok {
				break
			}
			time.sleep(3 * time.Millisecond)
		}
		fmt.printf(
			"[dup-probe] parked at frame %d: top(dup)_has_frame=%v below(orig)_has_frame=%v\n",
			playhead.frame,
			top_ok,
			below_ok,
		)
		dup_check(top_ok, "track-duplicated (top) clip never rendered a decoded slot")

		fmt.println("[dup-probe] file:", v)
		if duplicate_probe_fail {
			fmt.println("[dup-probe] FAILED")
			os.exit(1)
		}
		fmt.println("[dup-probe] OK")
		os.exit(0)
	}
}
