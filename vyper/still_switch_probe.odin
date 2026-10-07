package vyper

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// Debug-only probe, like flash_probe: it exists to prove something to
// scripts/gate.sh and is not part of a shipped binary.
when ODIN_DEBUG {

	// STILL_SWITCH_CLIPS is how many back-to-back stills each scenario walks. It must
	// be well past two so the handoff runs in steady state, where one clip is being
	// claimed while the next is being warmed.
	STILL_SWITCH_CLIPS :: 24

	// STILL_SWITCH_FRAME_PAUSE is the wall time between simulated frames. The app gives
	// a frame ~16 ms; 3 ms is deliberately stingier so a decode that only just fits in
	// a real frame cannot hide here, and it matches flash_probe's pacing.
	STILL_SWITCH_FRAME_PAUSE :: 3 * time.Millisecond

	// VYPER_STILL_SWITCH_PROBE="<img>|<img>[|<img>...]": play forward across a run of
	// back-to-back stills that cycle through the given images, at several clip lengths,
	// and require that the clip covering the playhead already has a decoded frame the
	// moment update_preview_slots() returns -- which is the moment the frame is drawn.
	// A covered clip with no frame is a black frame on screen.
	//
	// This is ~/spooky.vyproj: 3-frame stills, then 1-frame stills, cycling three
	// JPEGs. Every clip was a cold claim, because prewarm_next_clip ran before the
	// claim walk and, once the playhead entered clip N, retargeted the single warm
	// decoder to N+1 and reset the one warmed for N.
	//
	// The first clip of a run is cold by construction (nothing has been warmed
	// before playback starts), so counting starts at the second.
	still_switch_probe_run :: proc(v: string) {
		editor_flags.async_import_mode = false
		parts := strings.split(v, "|", context.temp_allocator)
		if len(parts) < 2 {
			fmt.println("[still-switch] need VYPER_STILL_SWITCH_PROBE=\"<img>|<img>[|<img>...]\"")
			os.exit(2)
		}
		ids := make([dynamic]u64, 0, len(parts), context.temp_allocator)
		for p in parts {
			id := import_media_to_bin(strings.clone_to_cstring(p, context.temp_allocator))
			if id == 0 {
				fmt.printf("[still-switch] FAIL could not bin %q\n", p)
				os.exit(2)
			}
			append(&ids, id)
		}
		async_live_mode = true

		failed := false
		for clip_len in ([]i64{1, 2, 3}) {
			drops := still_switch_walk(ids[:], clip_len)
			fmt.printf(
				"[still-switch] clip_len=%d clips=%d images=%d black_frames=%d\n",
				clip_len,
				STILL_SWITCH_CLIPS,
				len(ids),
				drops,
			)
			if drops != 0 {
				failed = true
			}
		}
		if failed {
			fmt.println("[still-switch] FAILED")
			os.exit(1)
		}
		fmt.println("[still-switch] ok (every still has a frame the moment it covers the playhead)")
	}

	// still_switch_walk lays STILL_SWITCH_CLIPS stills of `clip_len` frames end to end,
	// cycling through `ids`, plays forward across them, and returns how many frames,
	// after the first clip, had a covering clip with no decoded frame.
	still_switch_walk :: proc(ids: []u64, clip_len: i64) -> int {
		free_timeline(&timeline)
		append(&timeline.tracks, Track{})
		sync_track_order()
		// A full session reset between scenarios: the warm decoder and the slots of the
		// previous run would otherwise hand this one a head start it would not have.
		if warm.valid {
			clip_decoder_reset(&warm.decoder)
			warm.valid = false
			warm.clip_id = 0
		}
		async_dec_reset()
		invalidate_preview_slots()

		// Place far apart so placement never collides, then lay them end to end. Going
		// through add_asset_to_timeline makes real clips (path, size, is_still); only
		// their extent and position are overridden.
		far := i64(1000)
		for i in 0 ..< STILL_SWITCH_CLIPS {
			add_asset_to_timeline(ids[i % len(ids)], 0, i64(i) * far)
		}
		clips := &timeline.tracks[0].clips
		if len(clips) != STILL_SWITCH_CLIPS {
			fmt.printf("[still-switch] FAIL laid %d clips, wanted %d\n", len(clips), STILL_SWITCH_CLIPS)
			os.exit(2)
		}
		for i in 0 ..< len(clips) {
			clips[i].timeline_start_frame = i64(i) * clip_len
			clips[i].source_length_frames = clip_len
		}
		end := i64(STILL_SWITCH_CLIPS) * clip_len

		playhead.playing = true
		playback.dir = 1
		active_interaction = .None
		drops := 0
		for f := i64(0); f < end; f += 1 {
			playhead.frame = f
			update_preview_slots()
			if f < clip_len {
				time.sleep(STILL_SWITCH_FRAME_PAUSE)
				continue
			}
			covering: ^Clip
			for &c in clips {
				if clip_visible_at(f, c.timeline_start_frame, c.source_length_frames) {
					covering = &c
					break
				}
			}
			ok := false
			for s in 0 ..< MAX_PREVIEW_SLOTS {
				slot := &preview_slots[s]
				if slot.in_use && slot.has_frame && slot.clip_id == covering.clip_id {
					ok = true
				}
			}
			if !ok {
				drops += 1
				fmt.printf("[still-switch]   frame=%d clip_len=%d BLACK (covering clip has no frame)\n", f, clip_len)
			}
			time.sleep(STILL_SWITCH_FRAME_PAUSE)
		}
		return drops
	}
}
