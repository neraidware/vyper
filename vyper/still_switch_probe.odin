package vyper

import "core:fmt"
import "core:hash"
import "core:mem"
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

	// STILL_SCRUB_STEPS is how many pointer positions the scrub scenario visits, and
	// STILL_SCRUB_SEED fixes the sequence so a failure replays exactly. The positions are
	// a linear congruential walk over the whole run: scrubbing fast means consecutive
	// positions land in unrelated clips, not on neighbours.
	STILL_SCRUB_STEPS :: 400
	STILL_SCRUB_SEED  :: u64(0x2545F4914F6CDD1D)

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
		scrub_black, scrub_wrong := still_scrub_walk(ids[:], 3)
		fmt.printf(
			"[still-switch] scrub steps=%d images=%d black_on_revisit=%d wrong_pixels=%d\n",
			STILL_SCRUB_STEPS,
			len(ids),
			scrub_black,
			scrub_wrong,
		)
		if scrub_black != 0 || scrub_wrong != 0 {
			failed = true
		}
		lru_ok := still_lru_check(parts[0])
		fmt.printf("[still-switch] eviction_is_lru=%v\n", lru_ok)
		if !lru_ok {
			failed = true
		}
		edit_ok := still_edit_check(parts[0], parts[1])
		fmt.printf("[still-switch] edited_file_misses_cache=%v\n", edit_ok)
		if !edit_ok {
			failed = true
		}
		if failed {
			fmt.println("[still-switch] FAILED")
			os.exit(1)
		}
		fmt.println("[still-switch] ok (every still has a frame the moment it covers the playhead)")
	}

	// still_switch_lay resets the session and lays STILL_SWITCH_CLIPS stills of
	// `clip_len` frames end to end, cycling through `ids`.
	still_switch_lay :: proc(ids: []u64, clip_len: i64) {
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
	}

	// still_switch_walk lays STILL_SWITCH_CLIPS stills of `clip_len` frames end to end,
	// cycling through `ids`, plays forward across them, and returns how many frames,
	// after the first clip, had a covering clip with no decoded frame.
	still_switch_walk :: proc(ids: []u64, clip_len: i64) -> int {
		still_switch_lay(ids, clip_len)
		clips := &timeline.tracks[0].clips
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

	// still_scrub_walk lays the same run as still_switch_walk and then SCRUBS it: the
	// transport is parked (not playing, so prewarm never runs) and the pointer owns the
	// playhead, which jumps between unrelated clips each step. Every step is a cold
	// claim, so it measures what a decode costs when nothing was warmed.
	//
	// A black frame is only a defect on an image that has already been shown: the first
	// decode of a file is unavoidable, a repeat of one is just work already done and
	// thrown away. Returns the count of black frames on already-shown images.
	still_scrub_walk :: proc(ids: []u64, clip_len: i64) -> (black, wrong: int) {
		still_switch_lay(ids, clip_len)
		clips := &timeline.tracks[0].clips
		end := i64(STILL_SWITCH_CLIPS) * clip_len

		shown := make(map[u64]bool, len(ids), context.temp_allocator)
		// ref is the pixel hash of each image the first time it was shown. A cached
		// serve must reproduce it exactly: a frame on screen is not enough if it is the
		// wrong image, which is what an eviction or key bug would produce.
		ref := make(map[u64]u64, len(ids), context.temp_allocator)
		playhead.playing = false
		playback.dir = 1
		active_interaction = .Playhead_Scrub
		defer active_interaction = .None

		rng := STILL_SCRUB_SEED
		for step in 0 ..< STILL_SCRUB_STEPS {
			rng = rng * 6364136223846793005 + 1442695040888963407
			f := i64((rng >> 33) % u64(end))
			playhead.frame = f
			update_preview_slots()

			covering: ^Clip
			for &c in clips {
				if clip_visible_at(f, c.timeline_start_frame, c.source_length_frames) {
					covering = &c
					break
				}
			}
			has_frame := false
			pixels: u64
			for s in 0 ..< MAX_PREVIEW_SLOTS {
				slot := &preview_slots[s]
				if slot.in_use && slot.has_frame && slot.clip_id == covering.clip_id {
					has_frame = true
					pixels = hash.fnv64a(slot.buffer[:])
				}
			}
			if has_frame {
				shown[covering.asset_id] = true
				if want, seen := ref[covering.asset_id]; seen {
					if want != pixels {
						wrong += 1
						fmt.printf("[still-switch]   scrub step=%d frame=%d WRONG PIXELS for asset %d\n", step, f, covering.asset_id)
					}
				} else {
					ref[covering.asset_id] = pixels
				}
			} else if shown[covering.asset_id] {
				black += 1
				fmt.printf("[still-switch]   scrub step=%d frame=%d BLACK on an image already shown\n", step, f)
			}
			time.sleep(STILL_SWITCH_FRAME_PAUSE)
		}
		return black, wrong
	}

	// still_edit_check is the cache's one correctness hazard, checked at the cache itself:
	// an image replaced on disk while the session is open must MISS, not be served.
	// It deliberately does not go through update_preview_slots, because the async decode
	// worker keeps its own one-slot result per path and never re-checks the file, so
	// through the whole pipeline a stale picture could come from either layer and the
	// check could not say which one it was blaming (see TODO.md Active 44).
	//
	// Stores a still for a scratch file, requires a hit, rewrites the file, and requires
	// a miss.
	still_edit_check :: proc(a, b: string) -> bool {
		tmp_dir, terr := os.temp_directory(context.temp_allocator)
		if terr != nil {
			fmt.println("[still-switch] FAIL no temp directory")
			return false
		}
		scratch := fmt.tprintf("%s/still_switch_edit.jpg", tmp_dir)
		a_bytes, aerr := os.read_entire_file(a, context.temp_allocator)
		b_bytes, berr := os.read_entire_file(b, context.temp_allocator)
		if aerr != nil || berr != nil || os.write_entire_file(scratch, a_bytes) != nil {
			fmt.println("[still-switch] FAIL could not stage the edit fixture")
			return false
		}
		defer os.remove(scratch)

		// Preview_Slot carries a megabyte-class inline buffer: heap, never stack.
		stored := new(Preview_Slot)
		served := new(Preview_Slot)
		defer free(stored)
		defer free(served)
		path := strings.clone_to_cstring(scratch, context.temp_allocator)
		PICK :: u32(7)
		FRAME :: i64(0)
		stored.path = path
		served.path = path
		stored.buffer[0] = 0xAB
		still_cache_store(stored, PICK, FRAME)
		if !still_cache_serve(served, PICK, FRAME) || served.buffer[0] != 0xAB {
			fmt.println("[still-switch] FAIL an unchanged file did not hit the cache")
			return false
		}

		// A later modification time even on a filesystem with coarse timestamps.
		time.sleep(50 * time.Millisecond)
		if os.write_entire_file(scratch, b_bytes) != nil {
			fmt.println("[still-switch] FAIL could not rewrite the edit fixture")
			return false
		}
		served.has_frame = false
		if still_cache_serve(served, PICK, FRAME) {
			fmt.println("[still-switch] FAIL the edited file was served from the cache (old pixels)")
			return false
		}
		return true
	}

	// still_lru_check proves the eviction policy is recency, not use count. It fills the
	// cache, touches the OLDEST entry, then stores one more: the victim must be the
	// least recently touched (the second-oldest), and the touched one must survive. A
	// counter that only ever increases fails this, because the oldest entry would still
	// be the one with the smallest number.
	//
	// Entries are told apart by `pick` on one real file, so the file identity is valid
	// for all of them. Runs last: it empties the cache.
	still_lru_check :: proc(path: string) -> bool {
		mem.zero(&still_cache, size_of(still_cache))
		still_cache_clock = 0
		slot := new(Preview_Slot)
		defer free(slot)
		slot.path = strings.clone_to_cstring(path, context.temp_allocator)
		for pick in 0 ..< STILL_CACHE_SLOTS {
			still_cache_store(slot, u32(pick), 0)
		}
		if !still_cache_serve(slot, 0, 0) {
			fmt.println("[still-switch] FAIL lru: a stored entry missed")
			return false
		}
		NEWEST :: u32(STILL_CACHE_SLOTS)
		still_cache_store(slot, NEWEST, 0)
		slot.has_frame = false
		hits_oldest := still_cache_serve(slot, 0, 0)
		slot.has_frame = false
		hits_victim := still_cache_serve(slot, 1, 0)
		slot.has_frame = false
		hits_newest := still_cache_serve(slot, NEWEST, 0)
		if !hits_oldest || hits_victim || !hits_newest {
			fmt.printf(
				"[still-switch] FAIL lru: touched-oldest kept=%v least-recent evicted=%v newest kept=%v\n",
				hits_oldest,
				!hits_victim,
				hits_newest,
			)
			return false
		}
		return true
	}
}
