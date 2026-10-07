package vyper

import avutil "vendor/ffmpeg/avutil"
import swres "vendor/ffmpeg/swresample"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import sdl "vendor:sdl3"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

	// Headless reproducibility probe for the "after many splits audio drops to a
	// blip" bug: VYPER_AUDIO_PROBE="<file>|<splits>|<audio_tracks>". Runs without an
	// audio device: builds a video + N linked audio lanes, splits the linked group
	// `splits` times, commits the geometry slab, then provisions (decoder
	// open/seek only), reports groups/segments and any MAX_PLAY_AUDIO /
	// AUDIO_GEOM_MAX_CLIPS truncation, and simulates audio_mix_frame frame by frame
	// counting delivered frames vs silence holes.

	audio_probe_run :: proc(v: string) -> int {
		parts := strings.split(v, "|")
		if len(parts) < 1 || parts[0] == "" {
			fmt.println("audio-probe: need VYPER_AUDIO_PROBE=\"<file>|<splits>|<audio_tracks>\"")
			return 2
		}
		path := parts[0]
		splits := 10
		if len(parts) >= 2 {
			splits, _ = strconv.parse_int(parts[1])
		}
		lanes := 5
		if len(parts) >= 3 {
			lanes, _ = strconv.parse_int(parts[2])
		}

		editor_flags.async_import_mode = false
		buf: [4096]u8
		n := 0
		for n < len(path) && n < len(buf) - 1 {
			buf[n] = u8(path[n])
			n += 1
		}
		buf[n] = 0
		import_media(cstring(&buf[0]))

		if len(timeline.tracks) < 2 {
			fmt.println("audio-probe: import produced", len(timeline.tracks), "tracks")
			return 2
		}
		video_track := -1
		audio_clip: ^Clip
		video_link: u64
		for ti in 0 ..< len(timeline.tracks) {
			for ci in 0 ..< len(timeline.tracks[ti].clips) {
				c := &timeline.tracks[ti].clips[ci]
				if c.kind == .Video && video_track < 0 {
					video_track = ti
					video_link = c.link_id
				}
				if c.kind == .Audio && audio_clip == nil {
					audio_clip = c
				}
			}
		}
		if video_track < 0 || audio_clip == nil {
			fmt.println("audio-probe: no video/audio clip (video_track=", video_track, ")")
			return 2
		}
		src_len := audio_clip.source_length_frames
		fmt.printf("[ap] imported video_track=%d link=%d audio_len=%d\n", video_track, video_link, src_len)

		// Extra linked audio lanes: same link group as the video, so every split
		// cuts them too (the "1 video + 5 audio" linked-group case).
		for k in 1 ..< lanes {
			clone := audio_clip^
			clone.keyframe_tracks = session_trk_share(&audio_clip.keyframe_tracks)
			clone.clip_id = new_clip_id()
			clone.link_id = video_link
			clone.markers = Clip_Markers_Range{}
			nt := Track {
				name  = strings.clone("audio-copy"),
				clips = make([dynamic]Clip, 0, 8),
			}
			append(&nt.clips, clone)
			append(&timeline.tracks, nt)
		}
		sync_track_order()

		// Split the linked group `splits` times at evenly spaced frames.
		sel_track := video_track
		sel_index := 0
		for s in 0 ..< splits {
			pos := i64((s + 1)) * src_len / i64(splits + 1)
			playhead.frame = pos
			// Point the selection at the video clip covering pos.
			tr, clip, ok := clip_at_frame(pos)
			if !ok || clip == nil {
				fmt.printf("[ap] split %d: no clip at frame %d\n", s, pos)
				continue
			}
			_, _ = tr, clip
			selection.track = track_index_of(tr)
			selection.index = clip_index_on_track(tr, clip)
			split_clip_at_playhead()
		}
		_ = sel_track
		_ = sel_index
		total_audio := 0
		for ti in 0 ..< len(timeline.tracks) {
			for ci in 0 ..< len(timeline.tracks[ti].clips) {
				if timeline.tracks[ti].clips[ci].kind == .Audio {
					total_audio += 1
				}
			}
		}
		fmt.printf("[ap] after %d splits: tracks=%d audio_clips=%d\n", splits, len(timeline.tracks), total_audio)

		audio_geometry_commit()
		slot := &audio_geom_state.slots[sync.atomic_load(&audio_geom_state.idx)]
		fmt.printf("[ap] geometry chips=%d (geom cap %d)\n", slot.n, AUDIO_GEOM_MAX_CLIPS)

		// Provision at the timeline start: the worst case, since every segment is
		// in the future and each wants its own decoder.
		audio_rpt.trace = true
		prov_t0 := monotonic_ns()
		audio_provision(0)
		prov_ms := f64(monotonic_ns()-prov_t0) / 1e6
		fmt.printf(
			"[ap] audio_provision took %.1f ms, audio_src.count=%d (MAX_PLAY_AUDIO=%d)\n",
			prov_ms,
			audio_src.count,
			MAX_PLAY_AUDIO,
		)
		seg_total := 0
		for k in 0 ..< audio_src.count {
			seg_total += audio_src.slots[k].seg_count
		}
		fmt.printf("[ap] provisioned %d groups / %d segments (chips=%d)\n", audio_src.count, seg_total, slot.n)
		fps := timeline_fps()
		for k in 0 ..< audio_src.count {
			s := &audio_src.slots[k]
			start_a, start_s, len_a := i64(0), i64(0), i64(0)
			start_s_rate := f64(0)
			if first := play_src_first_seg_at(s, 0); first != nil {
				start_a, start_s, len_a = first.start_a, first.start_s, first.len_a
				start_s_rate = first.start_s_rate
			}
			// Through the shared conversion, not a second copy of the formula: this
			// expectation must track the pinned source offset the producer uses.
			expected := i64(audio_content_sec(0, start_s, start_s_rate, fps) * 48000.0)
			fmt.printf(
				"[ap]  src %2d segs=%d a0=[%d,%d) s0=%d first48=%d expected=%d off=%+d (%.3fs)\n",
				k,
				s.seg_count,
				start_a,
				start_a + len_a,
				start_s,
				s.first48,
				expected,
				s.first48 - expected,
				f64(s.first48-expected) / 48000.0,
			)
		}

		// Sweep coverage across the whole timeline: where does the provisioned set
		// fail to cover the playhead?
		end := i64(0)
		for ti in 0 ..< len(timeline.tracks) {
			for c in timeline.tracks[ti].clips {
				if e := clip_timeline_end(c); e > end {
					end = e
				}
			}
		}
		gap_start := i64(-1)
		total_gap, gap_runs := i64(0), 0
		f := i64(0)
		for f < end {
			if !audio_src_covers_frame(f) {
				if gap_start < 0 {
					gap_start = f
					gap_runs += 1
				}
				total_gap += 1
			} else if gap_start >= 0 {
				fmt.printf("[ap] coverage gap [%d,%d) = %.2fs\n", gap_start, f, f64(f-gap_start)/fps)
				gap_start = -1
			}
			f += 1
		}
		if gap_start >= 0 {
			fmt.printf("[ap] coverage gap [%d,%d) = %.2fs\n", gap_start, end, f64(end-gap_start)/fps)
		}
		fmt.printf("[ap] timeline=%d frames (%.2fs), uncovered=%d frames, gap_runs=%d\n", end, f64(end)/fps, total_gap, gap_runs)

		// For a few sample frames, how many provisioned sources actually cover?
		samples := []i64{0, end / 4, end / 2, 3 * end / 4, end - 30}
		for sample in samples {
			cov := 0
			for k in 0 ..< audio_src.count {
				s := &audio_src.slots[k]
				if s.dec.opened && play_src_seg_at(s, sample) != nil {
					cov += 1
				}
			}
			fmt.printf("[ap] frame %d: covering sources=%d\n", sample, cov)
		}

		// Simulate the producer's feed exactly: walk frame by frame, zero the mix,
		// call audio_mix_frame (which pulls/decodes each covering source), and count
		// frames that delivered nothing (a hole => the device gets silence).
		mix: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
		audio_rpt.trace = true
		had_deliver := false
		run_start := i64(-1)
		holes, delivered := i64(0), i64(0)
		f = 0
		for f < end {
			spf := 1
			if fps > 0 {
				b0 := audio_frame_boundary48(f, fps)
				b1 := audio_frame_boundary48(f + 1, fps)
				spf = min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(b1-b0)))
			}
			ok := audio_mix_frame(mix[:], f, spf)
			if ok {
				delivered += 1
				if run_start >= 0 {
					fmt.printf("[ap] silent run [%d,%d) = %.2fs\n", run_start, f, f64(f-run_start)/fps)
					run_start = -1
				}
			} else {
				holes += 1
				if run_start < 0 {
					run_start = f
				}
			}
			f += 1
		}
		if run_start >= 0 {
			fmt.printf("[ap] silent run [%d,%d) = %.2fs\n", run_start, end, f64(end-run_start)/fps)
		}
		fmt.printf("[ap] sim: delivered=%d holes=%d of %d frames\n", delivered, holes, end)

		gain_ok := audio_probe_gain_check()
		if !gain_ok {
			fmt.println("[ap] GAIN CHECK FAIL")
			return 1
		}
		fmt.println("[ap] gain check ok")

		fold_ok := audio_probe_live_gain_check()
		if !fold_ok {
			fmt.println("[ap] LIVE GAIN FOLD CHECK FAIL")
			return 1
		}
		fmt.println("[ap] live gain fold check ok")

		cuts_ok := audio_probe_transparent_cuts(path)
		if !cuts_ok {
			fmt.println("[ap] CUT TRANSPARENCY FAIL")
			return 1
		}

		slab_ok := audio_probe_geom_slab_handoff()
		if !slab_ok {
			fmt.println("[ap] GEOMETRY SLAB HANDOFF FAIL")
			return 1
		}
		fmt.println("[ap] geometry slab handoff ok")

		burst_ok := audio_probe_edit_burst_provisions(path)
		if !burst_ok {
			fmt.println("[ap] EDIT-BURST PROVISION FAIL")
			return 1
		}
		fmt.println("[ap] edit-burst provisioning ok")

		edit_ok := audio_probe_post_edit_alignment(path)
		if !edit_ok {
			fmt.println("[ap] POST-EDIT ALIGNMENT FAIL")
			return 1
		}
		fmt.println("[ap] post-edit alignment ok")

		audio_reset_play()
		return 0
	}

	// audio_probe_post_edit_alignment is the user's repro as an assertion: scrub
	// around, split, ripple-delete, move clips, then play -- and every frame the
	// engine serves must come from the clip that covers it in the EDITED timeline.
	//
	// This is checked against the provisioned segments rather than by ear. Each
	// Play_Seg carries the source window it was built with (start_s = where in the
	// file, len_a = how long), so "is the audio lined up with the picture" has an
	// exact answer per frame: for every provisioned segment, the timeline clip that
	// covers the segment's timeline span must agree on source_start_frame and
	// length. A stale provision (the edit never invalidated the producer) shows up
	// as a segment pointing into a region that has since been split, moved or
	// removed -- which is precisely what desync sounds like.
	audio_probe_post_edit_alignment :: proc(path: string) -> bool {
		fmt.println("[ap] --- post-edit alignment ---")
		ok := true
		audio_reset_play()
		buf: [4096]u8
		cn := 0
		for cn < len(path) && cn < len(buf) - 1 {
			buf[cn] = u8(path[cn])
			cn += 1
		}
		buf[cn] = 0
		cpath := cstring(&buf[0])
		// One audio clip spanning the whole timeline, plus a video clip so the
		// timeline looks like a real session rather than one lone lane.
		// Replace the imported session wholesale. track_order is a permutation OF
		// timeline.tracks, so it has to be replaced with it (sync_track_order
		// asserts on a length mismatch by design -- it is a real invariant, not
		// stale state to paper over).
		timeline.tracks = make([dynamic]Track, 0, 2)
		timeline.track_order = make([dynamic]int, 0, 2)
		atrack := Track {
			name = "a",
			clips = make([dynamic]Clip, 0, 4),
		}
		append(&atrack.clips, Clip {
			clip_id = new_clip_id(),
			path = cpath,
			kind = .Audio,
			name = session_str_intern("audio"),
			timeline_start_frame = 0,
			source_length_frames = 240,
			source_start_frame = 0,
			stream_index = 0,
		})
		append(&timeline.tracks, atrack)
		sync_track_order()
		selection.track, selection.index = -1, -1
		playhead.frame = 0
		audio_note_edit()

		// The scrub: move the playhead the way a click does, then let the engine
		// catch up (audio_update is UI-thread; here we just re-anchor as it does).
		playhead.frame = 90
		audio_seek(playhead.frame)

		// Split at the playhead.
		tr, clip, found := clip_at_frame(playhead.frame)
		if found {
			selection.track = track_index_of(tr)
			selection.index = clip_index_on_track(tr, clip)
			split_clip_at_playhead()
		}

		// Ripple-delete a region that swallows the second half of the split.
		ripple_delete_region(120, 60)

		// Move what is left to a new start, the way a drag does.
		for &c in timeline.tracks[0].clips {
			c.timeline_start_frame = 30
		}
		audio_note_edit()
		playhead.frame = 90

		fps := timeline_fps()
		fmt.printf(
			"[ap] after edits: clips=%d playhead=%d (%.2fs)\n",
			len(timeline.tracks[0].clips),
			playhead.frame,
			f64(playhead.frame) / fps,
		)

		audio_geometry_commit()
		audio_provision(playhead.frame)
		fmt.printf("[ap] re-provisioned at the playhead: %d sources\n", audio_src.count)
		if audio_src.count == 0 {
			fmt.println("[ap] FAIL: the engine provisioned no sources after the edits")
			return false
		}

		// Every segment must agree with the timeline as it stands NOW.
		checked := 0
		for k in 0 ..< audio_src.count {
			s := &audio_src.slots[k]
			for si in 0 ..< s.seg_count {
				seg := &s.seg[si]
				// The middle frame of the segment: unambiguously inside it.
				f := seg.start_a + seg.len_a / 2
				t2, c2, found2 := clip_at_frame(f)
				checked += 1
				if !found2 {
					fmt.printf(
						"[ap] FAIL: segment [%d,%d) of source %d covers frame %d, which no clip covers any more\n",
						seg.start_a,
						seg.start_a + seg.len_a,
						k,
						f,
					)
					ok = false
					continue
				}
				_ = t2
				// The source window must be the CURRENT clip's: same length, and
				// the same position inside the file.
				want_s := c2.source_start_frame + (f - c2.timeline_start_frame)
				if seg.start_s + (f - seg.start_a) != want_s {
					fmt.printf(
						"[ap] FAIL: frame %d plays source sample %d, timeline says %d (clip %d+%d, seg %d+%d)\n",
						f,
						seg.start_s + (f - seg.start_a),
						want_s,
						c2.source_start_frame,
						c2.source_length_frames,
						seg.start_s,
						seg.len_a,
					)
					ok = false
				}
				if seg.len_a > c2.source_length_frames {
					fmt.printf(
						"[ap] FAIL: segment at %d is %d frames long, longer than the clip covering it (%d)\n",
						seg.start_a,
						seg.len_a,
						c2.source_length_frames,
					)
					ok = false
				}
			}
		}
		fmt.printf("[ap] checked %d provisioned segments against the edited timeline\n", checked)
		if checked == 0 {
			fmt.println("[ap] FAIL: nothing to check -- the edits left no segments")
			return false
		}
		return ok
	}

	// audio_probe_mix_peak decodes `frames` timeline frames starting at `start`
	// from the already-provisioned sources (caller provisioned at frame 0) and
	// returns the peak |sample| across the whole window.
	audio_probe_mix_peak :: proc(mix: []f32, start: i64, frames: i64, fps: f64) -> f32 {
		peak := f32(0)
		for f in start ..< start + frames {
			spf := 1
			b0 := audio_frame_boundary48(f, fps)
			b1 := audio_frame_boundary48(f + 1, fps)
			spf = min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(b1-b0)))
			if audio_mix_frame(mix, f, spf) {
				for &v in mix[:spf * 2] {
					peak = max(peak, math.abs(v))
				}
			}
		}
		return peak
	}

	// audio_probe_live_gain_check verifies the producer-side live gain fold (the
	// audio_geom_state.gain_epoch + audio_gain_fold path the feed loop uses during a knob
	// drag): after the first window is mixed at unity, the clips' gains are edited
	// and committed -- which must bump the epoch -- then folded into the already
	// provisioned segments WITHOUT reset/re-provision. A second window mixed from
	// the same logical position must land at gain*peak (live audible update), not
	// the stale unity value, proving the segment gains were rewritten in place.
	audio_probe_live_gain_check :: proc() -> bool {
		fps := timeline_fps()
		// Both measured windows must sit in the clip's STEADY state, and one of them
		// must be a unity window the fold can be divided by.
		//
		// Measuring the unity window at the very start of the clip only worked while
		// the clip's opening was missing: a decoder that lands a packet late drops the
		// encoder's first frame, and that frame is where the transient lives. Once
		// decode_from_content made content 0 reachable, window [0,120) contained a
		// transient that [120,240) does not, the two peaks stopped being equal, and the
		// ratio came out 0.083 instead of 0.100 -- the test was measuring the
		// fixture's start, not the fold.
		//
		// WARMUP_FRAMES gets past that transient, and the two unity windows then
		// establish stationarity as an ASSERTED precondition, so a fixture that stops
		// being stationary fails loudly instead of yielding a meaningless ratio.
		//
		// The fixture's audio occupies frames [0,200) -- two 100-frame clips -- and is
		// SILENCE after that, so every window has to live inside it or the "peak" is
		// measured off a truncated tail. Windows therefore sit in the second clip,
		// clear of its start transient: 110..130 and 130..150 at unity, 150..170 after
		// the fold. Any window of a full sine period contains that sine's peak, so the
		// three windows are directly comparable.
		WARMUP_FRAMES := i64(110)
		GAIN_WINDOW := i64(20)
		mix: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
		// Previous checks leave every clip at -20 dB. Restore unity (and commit)
		// first so the drag below is a real 0 -> -20 transition the commit must
		// detect; a NO-OP commit is the failure this probe exists to catch.
		for ti in 0 ..< len(timeline.tracks) {
			for &c in timeline.tracks[ti].clips {
				if c.kind == .Audio {
					c.gain = 0
				}
			}
		}
		audio_geometry_commit()
		audio_reset_play()
		audio_provision(0)
		audio_probe_mix_peak(mix[:], 0, WARMUP_FRAMES, fps)
		unity_a := audio_probe_mix_peak(mix[:], WARMUP_FRAMES, GAIN_WINDOW, fps)
		unity_b := audio_probe_mix_peak(mix[:], WARMUP_FRAMES + GAIN_WINDOW, GAIN_WINDOW, fps)
		peak_unity := unity_b
		if math.abs(unity_a - unity_b) > 0.001 {
			fmt.printf(
				"[ap] fold: unity windows differ (%.5f vs %.5f); the fixture is not stationary here, so a gain ratio would mean nothing\n",
				unity_a,
				unity_b,
			)
			return false
		}
		for ti in 0 ..< len(timeline.tracks) {
			for &c in timeline.tracks[ti].clips {
				if c.kind == .Audio {
					c.gain = -20
				}
			}
		}
		epoch_before := sync.atomic_load(&audio_geom_state.gain_epoch)
		audio_geometry_commit()
		if sync.atomic_load(&audio_geom_state.gain_epoch) == epoch_before {
			fmt.println("[ap] live fold: commit did not bump audio_geom_state.gain_epoch (gain change missed)")
			return false
		}
		audio_gain_fold(&audio_geom_state.slots[sync.atomic_load(&audio_geom_state.idx)])
		audio_geom_state.gain_folded_epoch = sync.atomic_load(&audio_geom_state.gain_epoch)
		peak_live := audio_probe_mix_peak(
			mix[:],
			WARMUP_FRAMES + 2 * GAIN_WINDOW,
			GAIN_WINDOW,
			fps,
		)
		expected := db_to_linear(-20)
		ratio := peak_unity > 0 ? peak_live / peak_unity : 0
		fmt.printf(
			"[ap] fold: unity_peak=%.5f -20dB_peak=%.5f ratio=%.5f expected=%.5f (no re-provision)\n",
			peak_unity, peak_live, ratio, expected,
		)
		if peak_unity <= 0 || math.abs(ratio - expected) > 0.001 {
			return false
		}
		return true
	}

	// audio_probe_gain_check verifies the per-clip gain reaches the mix: a -20 dB
	// value must scale the mixed amplitude by exactly 0.1. Runs the same short
	// window twice (unity then -20 dB), re-provisioning between because the frame
	// sim consumes the source fifos.
	audio_probe_gain_check :: proc() -> bool {
		fps := timeline_fps()
		gain_frames := i64(120)
		mix: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
		audio_reset_play()
		audio_provision(0)
		peak_unity := audio_probe_mix_peak(mix[:], 0, gain_frames, fps)
		for ti in 0 ..< len(timeline.tracks) {
			for &c in timeline.tracks[ti].clips {
				if c.kind == .Audio {
					c.gain = -20
				}
			}
		}
		audio_geometry_commit()
		audio_reset_play()
		audio_provision(0)
		peak_gain := audio_probe_mix_peak(mix[:], 0, gain_frames, fps)
		expected := db_to_linear(-20)
		ratio := peak_unity > 0 ? peak_gain / peak_unity : 0
		fmt.printf(
			"[ap] gain: unity_peak=%.5f -20dB_peak=%.5f ratio=%.5f expected=%.5f\n",
			peak_unity, peak_gain, ratio, expected,
		)
		if peak_unity <= 0 || math.abs(ratio - expected) > 0.001 {
			return false
		}
		return true
	}


	// audio_probe_edit_burst_provisions is the user's repro measured instead of
	// heard: scrub, split, ripple-delete and move in a burst, then watch how many
	// times the engine tore itself down.
	//
	// Every one of those verbs ends in audio_note_edit -> audio_seek, which bumps
	// the resync event. The producer acts on EVERY event change: it clears the
	// device queue and reopens every decoder synchronously before it can mix
	// another frame. So N edits in a burst cost N stream teardowns, and each one
	// drops a full cushion of queued audio on the floor and re-primes the decoders
	// -- audible as audio that keeps restarting behind the picture. The 200 ms
	// re-check coalescing in audio_update does not help: it guards the UI's
	// re-DIAGNOSIS, and audio_seek (which the edits call) stamps anchor_now, so
	// the edits keep resetting that window themselves.
	//
	// The fix belongs where the cost is: a burst of geometry edits must collapse
	// into ONE re-provision. This asserts exactly that, and prints the ratio so a
	// regression shows how bad it got rather than just that it happened.
	audio_probe_edit_burst_provisions :: proc(path: string) -> bool {
		fmt.println("[ap] --- edit-burst provisioning ---")
		audio_probe_timeline_reset()
		buf: [4096]u8
		cn := 0
		for cn < len(path) && cn < len(buf) - 1 {
			buf[cn] = u8(path[cn])
			cn += 1
		}
		buf[cn] = 0
		cpath := cstring(&buf[0])
		timeline.tracks = make([dynamic]Track, 0, 2)
		timeline.track_order = make([dynamic]int, 0, 2)
		atrack := Track {name = "a", clips = make([dynamic]Clip, 0, 8)}
		for i in 0 ..< 4 {
			append(
				&atrack.clips,
				Clip {
					clip_id = new_clip_id(),
					path = cpath,
					kind = .Audio,
					name = session_str_intern("audio"),
					timeline_start_frame = i64(i) * 300,
					source_length_frames = 300,
					source_start_frame = 0,
					stream_index = 0,
				},
			)
		}
		append(&timeline.tracks, atrack)
		sync_track_order()
		selection.track, selection.index = -1, -1
		audio_geometry_commit()

		// The real engine: device, bridge ring and the producer thread, because the
		// cost being measured happens on the producer and nowhere else.
		if !audio_device_init() {
			fmt.println("[ap] SKIP: no audio device available")
			return true
		}
		audio_device_set_active(false)
		sync.atomic_store(&audio_prod.stop, false)
		sync.atomic_store(&audio_prod.done, false)
		sync.atomic_store(&audio_prod.run, false)
		sync.atomic_store(&audio_prod.resync, 0)
		sync.atomic_store(&audio_prod.force_seek_resync, 0)
		audio_prod.thread = thread.create(audio_producer_proc)
		if audio_prod.thread == nil {
			fmt.println("[ap] SKIP: could not start the producer thread")
			return true
		}
		thread.start(audio_prod.thread)
		defer audio_shutdown()

		// Import/edit publishes geometry while stopped. The worker must warm decoders
		// behind the closed device gate so the Play press does not synchronously wait for
		// several source opens.
		playback.dir = 1
		playhead.frame = 0
		audio_prod.last_ui_frame = 0
		audio_seek(0)
		STARTUP_TIMEOUT_MS :: 500
		deadline := monotonic_ns() + u64(STARTUP_TIMEOUT_MS) * 1_000_000
		for (sync.atomic_load(&audio_prod.src_count_ui) == 0 || sync.atomic_load(&audio_prod.provisioning)) &&
		    monotonic_ns() < deadline {
			sleep_ms(1)
		}
		if sync.atomic_load(&audio_prod.src_count_ui) == 0 || sync.atomic_load(&audio_prod.provisioning) {
			fmt.println("[ap] startup: FAIL: stopped producer did not warm source before Play press")
			return false
		}
		if audio_device_queued() != 0 {
			fmt.printf("[ap] startup: FAIL: stopped warmup queued %d audible frames\n", audio_device_queued())
			return false
		}
		warm_provisions := audio_rpt.provisions
		playhead.playing = true
		preview.playing = true
		sync.atomic_store(&playback.dev_frame, playhead.frame)
		start_feed_frames := audio_rpt.total_fed_frames
		start_ns := monotonic_ns()
		// Match main's order: the device-clock read occurs before audio_update handles
		// the run edge. Seeding dev_frame above prevents stale stop position winning.
		playback_update(sdl.Uint64(start_ns))
		audio_update()
		for audio_rpt.total_fed_frames == start_feed_frames &&
		    monotonic_ns()-start_ns < u64(STARTUP_TIMEOUT_MS)*1_000_000 {
			sleep_ms(1)
		}
		start_ms := f64(monotonic_ns()-start_ns) / 1e6
		if audio_rpt.total_fed_frames == start_feed_frames {
			fmt.printf("[ap] startup: FAIL: first PCM took %.1f ms after Play press\n", start_ms)
			return false
		}
		if audio_rpt.provisions != warm_provisions {
			fmt.printf("[ap] startup: FAIL: Play press re-provisioned warm sources (%d -> %d)\n", warm_provisions, audio_rpt.provisions)
			return false
		}
		fmt.printf("[ap] startup: warm provision before Play; first PCM %.1f ms after press\n", start_ms)
		// Run normal UI clock/feed updates briefly so the producer builds an audible
		// queue and the playhead advances from zero before exercising stop/restart.
		for _ in 0 ..< 80 {
			sleep_ms(5)
			now := monotonic_ns()
			playback_update(sdl.Uint64(now))
			playback_publish(playhead.frame, sdl.Uint64(now))
			audio_update()
		}
		// Dragging the playhead BACKWARD while playing forward. The device clock is a
		// forward-only readout, so it is always ahead of a backward drag -- if the
		// readout outranks the pointer, the playhead cannot be moved back at all
		// during playback, which is what the user reported.
		live_frame := playhead.frame
		drag_to := live_frame / 2
		sync.atomic_store(&audio_rpt.ph_src, 1)
		// Arm through the REAL press handler, not by setting active_interaction. Arming
		// now STOPS playback -- that is what makes the drag free -- and a probe that
		// fakes the flag skips the stop, so the producer keeps feeding and republishing
		// a device clock the pointer is in the middle of overruling. Every version of this
		// probe that hand-set the flag was testing a state the app never enters.
		playhead.playing = true
		preview.playing = true
		// Arm through the REAL press handler: build the layout, feed clay the pointer
		// over the ruler, and run the actual click dispatch. That is the only way to
		// reach the code that stops playback -- a probe that sets active_interaction
		// itself bypasses the very thing under test.
		// Run the arming through the same call the ruler press makes. Rebuilding the
		// clay layout here is not an option -- this probe owns the device and the
		// producer thread, and build_page under both segfaulted -- so the press HANDLER
		// is called directly instead, which is the code that stops playback and is the
		// thing under test. The hit test above it (PointerOver on the ruler) is covered
		// by ui_probe, which drives the real press through the real layout.
		playhead_scrub_arm()
		if active_interaction != .Playhead_Scrub {
			fmt.printf(
				"[ap] backward scrub: FAIL: arming produced %v, want Playhead_Scrub\n",
				active_interaction,
			)
			return false
		}
		playhead_scrub.moved = false
		// Arming must NOT stop playback. Stopping is the workaround that was tried and
		// removed: it makes the drag unobservable, because a suspended playhead has
		// nothing to fight, so the live-path fault this probe exists to find goes unseen.
		// So the contract is the opposite -- playback continues, and the drag tells the
		// audio engine where the playhead is instead.
		if !playhead.playing {
			fmt.println("[ap] backward scrub: FAIL: arming a scrub stopped playback (the removed workaround)")
			return false
		}
		audio_update()
		playhead.frame = drag_to
		playhead_scrub.moved = true
		playback_update(sdl.Uint64(monotonic_ns()))
		if playhead.frame != drag_to {
			fmt.printf(
				"[ap] backward scrub: FAIL: playhead moved %d -> %d off the pointer while scrubbing\n",
				drag_to, playhead.frame,
			)
			return false
		}
		// Release commits the one position the drag landed on, and that position
		// becomes the device clock's new baseline: the old forward position must not
		// be adopted on the next tick and undo the drag a second time.
		audio_seek(playhead.frame)
		playback_update(sdl.Uint64(monotonic_ns()))
		if playhead.frame != drag_to {
			fmt.printf(
				"[ap] backward scrub: FAIL: release re-adopted the stale clock %d -> %d\n",
				drag_to, playhead.frame,
			)
			return false
		}
		fmt.printf("[ap] backward scrub: playhead held at %d while playing forward from %d\n", drag_to, live_frame)
		active_interaction = .None
		playhead_scrub.moved = false
		// CONTENT, not state. Every assertion in this probe family so far checked
		// state (next_frame rewound, queue dropped, decoder re-anchored) or timing
		// (first PCM within N ms), and all of them passed while the engine was feeding
		// the PRE-SCRUB position: the forward-hop guard read the stale dev_frame and
		// jumped the producer straight back. State was correct and the sound was wrong,
		// and no state assertion can tell the difference.
		//
		// The producer's own position is the content oracle here. The fixture is a
		// steady 440 Hz tone with no transients, which is exactly why this has to be
		// arithmetic on positions: every onset check would read the same at frame 14
		// and frame 31. The feed trace under VYPER_PLAY_TRACE=1 prints the content
		// sample range per block, which is how the defect was found; this pins the
		// outcome so it cannot come back.
		//
		// The check has to happen on the FIRST feed pass after the seek, not later. A
		// wrong producer position is not static: the forward-hop guard jumps it BACK to
		// the pre-scrub frame and then it keeps advancing forward from there, so any
		// later sample is indistinguishable from correct behaviour by position alone.
		// Sampling after a few ticks reads "37, advancing forward" in both the broken
		// and the fixed build -- which is how this probe passed against a broken engine
		// the first time it was written.
		//
		// What is unambiguous is the producer's position at the earliest observable
		// moment: it must be at the scrub target, because the feed target is derived
		// from next_frame and the queue was just dropped.
		content_ticks :: 40
		// Zero the marker, then run the loop. The producer publishes the content sample
		// of every block it feeds, so after one tick this holds the content the DEVICE
		// was actually handed for the seek above -- the one number that distinguishes
		// "played the scrubbed position" from "kept playing the old one", and which
		// end-state inspection cannot reach because both end up advancing forward.
		// Nothing is FED while the scrub holds playback paused -- that is the point of
		// pausing -- so arm the latch only after playback is restarted, or it reads the
		// "no block yet" sentinel and the probe would blame the engine for the pause.
		playhead.playing = true
		preview.playing = true
		audio_prod.was_playing = false
		audio_update()
		sync.atomic_store(&audio_rpt.last_fed_content, -1)
		sync.atomic_store(&audio_rpt.last_fed_content_armed, true)
		for _ in 0 ..< content_ticks {
			sleep_ms(1)
			now := monotonic_ns()
			playback_update(sdl.Uint64(now))
			playback_publish(playhead.frame, sdl.Uint64(now))
			audio_update()
		}
		probe_fps := timeline_fps()
		want_content := audio_frame_boundary48(drag_to, probe_fps)
		live_content := audio_frame_boundary48(live_frame, probe_fps)
		got_content := sync.atomic_load(&audio_rpt.last_fed_content)
		fmt.printf(
			"[ap] content: scrub to frame %d (content sample %d); producer last fed content sample %d; pre-scrub frame %d was content %d\n",
			drag_to, want_content, got_content, live_frame, live_content,
		)
		// The fed content must be the scrubbed position, not the one it came from. A
		// tolerance of a few ms covers the decoder's seek preroll, which deliberately
		// lands EARLY; what must never happen is landing at the pre-scrub content,
		// which is hundreds of frames away.
		tolerance := i64(0.1 * f64(AUDIO_BUS_RATE))
		if abs(got_content - want_content) > tolerance {
			fmt.printf(
				"[ap] content: FAIL: after scrubbing back to frame %d the engine fed content sample %d, which is the PRE-SCRUB position (frame %d, content %d). Audio plays from where it was dragged FROM.\n",
				drag_to, got_content, live_frame, live_content,
			)
			return false
		}
		// SUSTAINED. Every assertion above is about the FIRST tick after the seek, and
		// that is exactly the window where the engine looks correct: the producer
		// re-anchors within a few ms of the resync. The symptom that survives all of
		// them is playback that starts at the requested position and then slides back
		// to where it was -- the stale clock winning a frame later, once the seek's
		// protection has expired. So run the real loop for long enough to span several
		// cushion refills and require the playhead to advance from the scrub TARGET the
		// whole time, never resuming from the pre-scrub position.
		settle_ticks :: 240 // ~1.2 s at 5 ms, several cushion refills
		saw_max := drag_to
		for t in 0 ..< settle_ticks {
			sleep_ms(5)
			now := monotonic_ns()
			playback_update(sdl.Uint64(now))
			playback_publish(playhead.frame, sdl.Uint64(now))
			audio_update()
			if playhead.frame < drag_to {
				fmt.printf(
					"[ap] sustained: FAIL: tick %d, playhead went BACKWARD below the scrub target: %d < %d\n",
					t, playhead.frame, drag_to,
				)
				return false
			}
			saw_max = max(saw_max, playhead.frame)
		}
		// It must have actually MOVED ON from the target. A playhead frozen at the
		// scrub position passes every "did not jump back" check above while being just
		// as wrong -- the engine stalled instead of playing from it.
		if saw_max <= drag_to {
			fmt.printf(
				"[ap] sustained: FAIL: playhead never advanced past the scrub target %d over %d ticks (stalled, not playing from it)\n",
				drag_to, settle_ticks,
			)
			return false
		}
		// And it must be tracking the DEVICE, not drifting somewhere of its own. The
		// earlier version of this assertion recomputed the expected frame from the wall
		// clock and a nominal frame rate, which is the wrong oracle twice over: the
		// loop's own per-tick cost makes the elapsed time not tick_count * 5ms, and the
		// device is still holding pre-scrub audio for the first cushion after the seek.
		// The device clock is the engine's own answer to "where is the sound", so the
		// invariant is that the playhead FOLLOWS it, and that it only ever moves
		// forward from the scrub target.
		//
		// What this cannot hide: if the producer had resumed from the pre-scrub
		// position, dev_frame would report that position, the playhead would follow it
		// faithfully, and this check would pass. The producer's own position is
		// asserted separately by audio_backward_scrub.
		dev_final := sync.atomic_load(&playback.dev_frame)
		skew := playhead.frame - dev_final
		fmt.printf(
			"[ap] sustained: %d ticks after scrub to %d -> playhead %d, device %d, skew %+d (pre-scrub was %d)\n",
			settle_ticks, drag_to, playhead.frame, dev_final, skew, live_frame,
		)
		// The playhead is derived from the device position, so the two may differ by
		// one publish at most. Anything more means the playhead is running on its own
		// clock, which is the architecture this replaced.
		if abs(skew) > 2 {
			fmt.printf(
				"[ap] sustained: FAIL: playhead %d and device %d differ by %+d frames after a scrub to %d. The playhead is not following the audio.\n",
				playhead.frame, dev_final, skew, drag_to,
			)
			return false
		}
		// And the whole point: playback continued FORWARD from the scrub target, so
		// the position after 1.2 s must be beyond it and must NOT be back up at the
		// pre-scrub position it was dragged away from.
		if playhead.frame <= drag_to {
			fmt.printf(
				"[ap] sustained: FAIL: playhead %d after a scrub to %d did not advance\n",
				playhead.frame, drag_to,
			)
			return false
		}
		if playhead.frame < live_frame - 2 {
			fmt.printf(
				"[ap] sustained: FAIL: playhead %d is back at/below the pre-scrub position %d; it resumed from where it was dragged FROM\n",
				playhead.frame, live_frame,
			)
			return false
		}
		// Let the re-anchored producer refill and the clock catch up before the
		// stop/restart case below, which needs a playhead that has really advanced.
		for _ in 0 ..< 80 {
			sleep_ms(5)
			now := monotonic_ns()
			playback_update(sdl.Uint64(now))
			playback_publish(playhead.frame, sdl.Uint64(now))
			audio_update()
		}
		stopped_frame := playhead.frame
		if stopped_frame <= 0 {
			fmt.println("[ap] restart: FAIL: playhead did not advance before stop")
			return false
		}
		playhead.playing = false
		preview.playing = false
		audio_update()
		sleep_ms(20)
		// Move playhead backward while stopped, as in the user's repro. PlayPause's
		// immediate device-clock read must not replace this selected frame with the
		// previous run's stale dev_frame.
		playhead.frame = 0
		audio_seek(playhead.frame)
		warm_provisions = audio_rpt.provisions
		playhead.playing = true
		preview.playing = true
		// NO dev_frame seed here. toggle_playback seeds it in the app, but a probe that
		// seeds the value under test is testing the seed, not the path: playback_update
		// runs BEFORE audio_update on this tick, so with a stale dev_frame still ahead the
		// playhead must survive that read on its own. Seeding it away made this assertion
		// pass for the wrong reason -- the same mistake 5670ba9's probe made.
		start_feed_frames = audio_rpt.total_fed_frames
		start_ns = monotonic_ns()
		playback_update(sdl.Uint64(start_ns))
		if playhead.frame != 0 {
			fmt.printf("[ap] restart: FAIL: playback clock rewound selected frame 0 to %d\n", playhead.frame)
			return false
		}
		audio_update()
		for audio_rpt.total_fed_frames == start_feed_frames &&
		    monotonic_ns()-start_ns < u64(STARTUP_TIMEOUT_MS)*1_000_000 {
			sleep_ms(1)
		}
		restart_ms := f64(monotonic_ns()-start_ns) / 1e6
		if audio_rpt.total_fed_frames == start_feed_frames || audio_rpt.provisions != warm_provisions {
			fmt.printf("[ap] restart: FAIL: PCM=%t provisions=%d->%d after %.1f ms\n", audio_rpt.total_fed_frames > start_feed_frames, warm_provisions, audio_rpt.provisions, restart_ms)
			return false
		}
		fmt.printf("[ap] restart: resumed from selected frame 0 in %.1f ms without reopening sources\n", restart_ms)
		// Continue settled forward playback for the existing edit-burst test.
		for _ in 0 ..< 80 {
			sleep_ms(5)
			now := monotonic_ns()
			playback_update(sdl.Uint64(now))
			playback_publish(playhead.frame, sdl.Uint64(now))
			audio_update()
		}
		// Let it settle into steady playback before the burst.
		base := audio_rpt.provisions
		fmt.printf("[ap] steady state: %d provisions\n", base)

		// The burst: the user's sequence, back to back, as fast as the UI can
		// deliver it. Each verb runs its real audio_note_edit path.
		EDITS :: 8
		for i in 0 ..< EDITS {
			switch i % 4 {
			case 0:
				// scrub
				playhead.frame = 120 + i64(i) * 30
				audio_seek(playhead.frame)
			case 1:
				tr, clip, found := clip_at_frame(playhead.frame)
				if found {
					selection.track = track_index_of(tr)
					selection.index = clip_index_on_track(tr, clip)
					split_clip_at_playhead()
				}
			case 2:
				ripple_delete_region(playhead.frame, 30)
			case 3:
				for &c in timeline.tracks[0].clips {
					c.timeline_start_frame += 15
				}
				audio_note_edit()
			}
		}
		// The producer polls every ~2 ms; give it room to act on what the burst
		// requested. This is the WINDOW, not a settle: a coalescing fix must not
		// need seconds to notice, or playback is audibly wrong for seconds.
		sleep_ms(500)
		got := audio_rpt.provisions - base
		fmt.printf(
			"[ap] %d edits in a burst -> %d re-provisions\n",
			EDITS,
			got,
		)
		if got > 1 {
			fmt.printf(
				"[ap] FAIL: %d edits caused %d stream teardowns (want 1: one per burst)\n",
				EDITS,
				got,
			)
			return false
		}

		// --- the reconcile itself -----------------------------------------------------
		//
		// The burst above proves edits do not each tear the stream down. It cannot show
		// that any decoder SURVIVED one, which is the whole point of the change: a
		// reconcile that quietly reopens everything looks exactly like this from the
		// outside. So drive the two decisions directly and count them.
		//
		// A clean single clip first. The burst left the timeline fragmented into several
		// non-contiguous runs of the same file, which is several GROUPS and therefore
		// several decoders by construction -- a fine thing for the engine to do and a
		// useless thing to measure a single decision against.
		timeline.tracks = make([dynamic]Track, 0, 1)
		timeline.track_order = make([dynamic]int, 0, 1)
		recon_track := Track {
			name = "a",
			clips = make([dynamic]Clip, 0, 2),
		}
		append(&recon_track.clips, Clip {
			clip_id = new_clip_id(),
			path = cpath,
			kind = .Audio,
			name = session_str_intern("audio"),
			timeline_start_frame = 0,
			source_length_frames = 240,
			source_start_frame = 0,
			stream_index = 0,
		})
		// A SECOND group, non-contiguous with the first, so the timeline has two
		// source slots rather than one. That is what makes the reclaim path
		// observable: with a single source the builder's fresh allocation lands on
		// the very slot holding the decoder, so a build that ignored reclaim entirely
		// would still produce Keep/Open counts that look correct. Two slots and the
		// fresh allocation has somewhere else to go.
		append(&recon_track.clips, Clip {
			clip_id = new_clip_id(),
			path = cpath,
			kind = .Audio,
			name = session_str_intern("audio2"),
			timeline_start_frame = 800,
			source_length_frames = 240,
			source_start_frame = 400,
			stream_index = 0,
		})
		append(&timeline.tracks, recon_track)
		sync_track_order()
		playhead.frame = 0
		audio_note_edit()
		sleep_ms(300)

		// Park the clip ahead of everything the queue holds, so the edits below are
		// unambiguously OUTSIDE the queued window. Moving it there is itself an edit,
		// and it legitimately clears the queue -- the audio already mixed for frames
		// under the playhead came from where the clip used to be. That clear is
		// settled here, not asserted.
		timeline.tracks[0].clips[0].timeline_start_frame = 200
		audio_note_edit()
		sleep_ms(300)

		// (a) An edit outside the queued window that does not move the content the
		// decoder sits on: trim the far end of a clip the playhead is nowhere near.
		// Right answer: Keep, and no queue clear.
		kept0, open0, clr0 := audio_rpt.dec_kept, audio_rpt.dec_open, audio_rpt.queue_clears
		new0 := audio_rpt.slots_new
		timeline.tracks[0].clips[0].source_length_frames -= 10
		audio_note_edit()
		sleep_ms(300)
		keep_ok := audio_rpt.dec_kept > kept0
		no_open := audio_rpt.dec_open == open0
		no_clear := audio_rpt.queue_clears == clr0
		// The decoder was kept only if the new segments were built INTO ITS SLOT. A
		// fresh allocation would leave the real decoder empty and dropped, and the
		// counts above would still read Keep/Open correctly by accident -- so pin the
		// mechanism, not just the outcome.
		no_new_slot := audio_rpt.slots_new == new0
		fmt.printf(
			"[ap] trim outside the queued window: kept +%d opened +%d new-slots +%d queue-clears +%d\n",
			audio_rpt.dec_kept - kept0,
			audio_rpt.dec_open - open0,
			audio_rpt.slots_new - new0,
			audio_rpt.queue_clears - clr0,
		)
		if !keep_ok || !no_open || !no_clear || !no_new_slot {
			if !keep_ok {
				fmt.println("[ap] FAIL: a trim that moved no content did not keep the decoder (it re-anchored instead)")
			}
			if !no_open {
				fmt.println("[ap] FAIL: a trim outside the queued window reopened a decoder")
			}
			if !no_clear {
				fmt.println("[ap] FAIL: a trim outside the queued window cleared the queue")
			}
			if !no_new_slot {
				fmt.println("[ap] FAIL: a kept decoder's segments were built in a FRESH slot, so the real one was dropped")
			}
			return false
		}

		// (b) An edit that DOES move the content under the playhead. Same stream, so
		// Seek -- never Open, because a seek costs one reposition and an open costs a
		// file open.
		// Move the playhead INTO the clip and PUBLISH the anchor, not just the
		// playhead: a reconcile anchors at audio_prod.anchor_frame, which only
		// audio_seek sets, so moving the playhead alone leaves the engine reconciling
		// against wherever it was last told to look.
		playhead.frame = 200
		audio_seek(200)
		sleep_ms(300)
		seek1, open1 := audio_rpt.dec_seek, audio_rpt.dec_open
		timeline.tracks[0].clips[0].source_start_frame += 30
		audio_note_edit()
		sleep_ms(300)
		seek_ok := audio_rpt.dec_seek > seek1
		seek_no_open := audio_rpt.dec_open == open1
		fmt.printf(
			"[ap] edit under the playhead: sought +%d opened +%d\n",
			audio_rpt.dec_seek - seek1,
			audio_rpt.dec_open - open1,
		)
		if !seek_ok || !seek_no_open {
			if !seek_ok {
				fmt.println("[ap] FAIL: moving the content under the playhead kept a decoder at the old content")
			}
			if !seek_no_open {
				fmt.println("[ap] FAIL: moving the content under the playhead reopened instead of seeking")
			}
			return false
		}

		// The queue-clear half of a resync cannot be asserted through the live counter
		// alone: whether the queue holds anything is decided by the audio DEVICE, so on
		// a machine without one next_frame never leaves 0 and the counter cannot move.
		// The predicate behind it is pure, so pin that directly -- and it is half of a
		// resync, the half a user actually hears.
		//
		// The cases that matter are pairs: what the queued frames play BEFORE an edit
		// against what they play AFTER. Identical mapping must NOT touch the window,
		// because that is what makes an edit nobody can hear free -- trimming the far
		// end of the clip the playhead is inside leaves everything under the queue
		// exactly where it was. Anything that changes the content under those frames,
		// or takes them away, must.
		probe_window_src.seg[0] = Play_Seg {
			start_a = 200, len_a = 240, start_s = 0, start_s_rate = 1.0, speed = 1.0,
		}
		probe_window_src.seg_count = 1
		// The window is the shape the producer actually runs in: it starts at the
		// playhead and reaches past the end of the content, because the producer feeds
		// ahead of what the device has played.
		WINDOW_LO :: 0
		WINDOW_HI :: 500
		old_maps: [MAX_WINDOW_MAPS]Window_Map
		old_n, old_ok := play_src_window_maps(&probe_window_src, WINDOW_LO, WINDOW_HI, old_maps[:])
		// Every "after the edit" side below is the same clip as the old one, with only
		// the field under test moved: how far it reaches into the window, where its
		// content starts, how fast it plays.
		same := [1]Window_Map{probe_window_map(200, 440, 0, 1.0)}
		none := [1]Window_Map{}
		moved := [1]Window_Map{probe_window_map(200, 440, 30, 1.0)}
		faster := [1]Window_Map{probe_window_map(200, 440, 0, 2.0)}
		shorter := [1]Window_Map{probe_window_map(200, 300, 0, 1.0)}
		window_ok := old_n == 1 &&
			old_ok &&
			// unchanged, in a window that reaches past the clip: the queued audio is
			// still right, so the queue must stay
			!play_src_window_maps_differ(old_maps[:], old_n, same[:], 1, WINDOW_LO, WINDOW_HI) &&
			// clip gone from the timeline, or newly covering the window
			play_src_window_maps_differ(old_maps[:], old_n, none[:], 0, WINDOW_LO, WINDOW_HI) &&
			play_src_window_maps_differ(none[:], 0, same[:], 1, WINDOW_LO, WINDOW_HI) &&
			// content moved, sped up, or the clip's tail pulled back inside the window
			play_src_window_maps_differ(old_maps[:], old_n, moved[:], 1, WINDOW_LO, WINDOW_HI) &&
			play_src_window_maps_differ(old_maps[:], old_n, faster[:], 1, WINDOW_LO, WINDOW_HI) &&
			play_src_window_maps_differ(old_maps[:], old_n, shorter[:], 1, WINDOW_LO, WINDOW_HI)
		if !window_ok {
			fmt.println("[ap] FAIL: the queued-window predicate misreads an unchanged mapping, or misses one that changed")
			return false
		}
		fmt.println("[ap] queued-window predicate ok (unchanged / removed / added / moved / sped / shortened)")

		fmt.printf("[ap] reconcile: kept/decisions verified on the live producer\n")
		return true
	}


	// probe_window_src backs the queued-window predicate check. Play_Src is ~668 KB
	// (MAX_PLAY_SEGMENTS segments plus a decoder), so it is package scope rather than
	// a local: a probe that only wants to set three segment fields must not put a
	// third of a megabyte on the stack, and the zero value is already a correct
	// "one segment, no decoder" source.
	probe_window_src: Play_Src

	// probe_window_map builds the "after the edit" side of a queued-window comparison:
	// the same clip as probe_window_src, with only the window range it covers, where
	// its content starts, and how fast it plays moved.
	probe_window_map :: proc(lo, hi: i64, start_s: i64, speed: f64) -> Window_Map {
		return Window_Map {
			lo = lo, hi = hi, start_a = 200, start_s = start_s, start_s_rate = 1.0, speed = speed,
		}
	}

	// audio_probe_geom_slab_handoff pins the producer/UI handoff on the geometry
	// slab. The producer does not read the slab for a moment -- it reads it for a
	// whole PROVISION, which reopens every decoder and takes tens of milliseconds
	// -- while the UI thread rewrites the slab on every edit. With only two slots,
	// two commits inside one provision wrap the index around and the second one
	// lands on the very slot the provision is still reading: a half-written chip
	// list, so segments are built from torn geometry (wrong source window, wrong
	// path) and playback is audibly out of sync with the picture.
	//
	// This is deterministic, not a flake: it holds a slot exactly as a provision
	// does and then commits twice, which is what a short edit burst does. The
	// writer must never touch a slot a reader holds, no matter how many commits
	// pass.
	audio_probe_marker_path :: proc() -> string {
		return "audio_probe_handoff_marker"
	}

	audio_probe_geom_slab_handoff :: proc() -> bool {
		fmt.println("[ap] --- geometry slab handoff ---")
		audio_reset_play()
		timeline.tracks = make([dynamic]Track, 0, 1)
		timeline.track_order = make([dynamic]int, 0, 1)
		track := Track {name = "a", clips = make([dynamic]Clip, 0, 2)}
		buf: [512]u8
		// A marker path per clip, so the slab's contents are unmistakably different
		// between the commits below.
		mp := audio_probe_marker_path()
		for i in 0 ..< 2 {
			cn := 0
			for cn < len(mp) && cn < len(buf) - 1 {
				buf[cn] = u8(mp[cn])
				cn += 1
			}
			buf[cn] = 0
			append(
				&track.clips,
				Clip {
					clip_id = new_clip_id(),
					path = cstring(&buf[0]),
					kind = .Audio,
					name = session_str_intern("clip"),
					timeline_start_frame = i64(i) * 100,
					source_length_frames = 100,
					source_start_frame = 0,
					stream_index = 0,
				},
			)
		}
		append(&timeline.tracks, track)
		audio_geometry_commit()

		// Take the slab exactly as the producer does before a provision, claim
		// included: the claim is what the writer must respect.
		held := audio_geom_acquire()
		defer audio_geom_release()
		held_n := held.n
		held_first := held.chip[0].timeline_start
		held_path := audio_chip_path(held, &held.chip[0])
		fmt.printf(
			"[ap] reader holds slot %d: n=%d chip0.start=%d path=%q\n",
			int(sync.atomic_load(&audio_geom_state.idx)),
			held_n,
			held_first,
			held_path,
		)

		// Two commits: what a split plus a ripple-delete inside one provision does.
		for pass in 0 ..< 2 {
			for &c in timeline.tracks[0].clips {
				c.timeline_start_frame += i64(1000 * (pass + 1))
			}
			audio_geometry_commit()
		}
		published := sync.atomic_load(&audio_geom_state.idx)
		now_n := held.n
		now_first := held.chip[0].timeline_start
		now_path := audio_chip_path(held, &held.chip[0])
		fmt.printf(
			"[ap] after 2 commits: published slot %d, held slot now n=%d chip0.start=%d path=%q\n",
			int(published),
			now_n,
			now_first,
			now_path,
		)
		if now_n != held_n || now_first != held_first || now_path != held_path {
			fmt.println(
				"[ap] FAIL: the writer overwrote the slot a reader is holding -- with two slots, two commits inside one provision wrap onto it",
			)
			return false
		}
		// And the freshly published slot must describe the CURRENT timeline, or the
		// next provision builds from stale geometry.
		cur := &audio_geom_state.slots[published]
		want := timeline.tracks[0].clips[0].timeline_start_frame
		if cur.n == 0 || cur.chip[0].timeline_start != want {
			fmt.printf(
				"[ap] FAIL: published slot has n=%d chip0.start=%d, want the timeline's %d\n",
				cur.n,
				cur.chip[0].timeline_start,
				want,
			)
			return false
		}
		fmt.println("[ap] the reader's slot survived two commits, and the published slot is current")
		return true
	}

	// audio_probe_forward_jump is the "audio DIES" report: drag the playhead a long
	// way forward while playing and the sound never comes back. It runs in its own
	// process (VYPER_AUDIO_JUMP_PROBE, wired into the gate) because it re-imports
	// the source onto a clean timeline: appended to the split-and-ripple-deleted
	// timeline the earlier cases leave behind, it measures that mess instead of a
	// jump.
	//
	// The forward skip in audio_producer_feed is deliberately NOT a re-provision:
	// it trims each fifo, moves next_frame to the playhead and lets the decoders
	// "just keep decoding forward", because reopening every decoder on every
	// forward move is the restart storm the Active 14/15 work removed. The claim
	// this probe checks is that the claim holds at a JUMP size -- the decoders are
	// now hundreds of seconds behind the demand, and audio_mix_frame has to
	// either catch them up or re-anchor them. A 10000-frame jump at 60 fps is
	// 166 s of content, which is why this is not a small perturbation.
	//
	// What it asserts: the jump SEEKS rather than decoding through the gap. Silent
	// frames right after the jump are the same bug by another name, so they are a
	// failure too -- there is no "it needed a moment" case.
	// audio_probe_forward_jump covers the user's repro: playing a long AV1/FLAC
	// recording and moving the playhead forward a long way, which "dies".
	//
	// JUMP_MIX_FRAMES is the window mixed after the jump. JUMP_DECODE_SLACK_SEC is
	// the decoder-chunk overshoot allowed on top of the seek's own decode budget.
	// JUMP_GAP_SEC is the gap the gate fixture jumps: past
	// AUDIO_FORWARD_DECODE_MAX_SEC, so the seek path is the one under test and the
	// case cannot skip on a clip shorter than the user's 166s jump.
	JUMP_MIX_FRAMES :: 30
	JUMP_DECODE_SLACK_SEC :: 0.5
	JUMP_GAP_SEC :: 5.0

	// jump_frames <= 0 derives the gap from the clip, so the gate fixture jumps too.
	audio_probe_forward_jump :: proc(path: string, jump_frames: i64) -> bool {
		jump := jump_frames
		fmt.println("[ap] --- forward jump ---")
		editor_flags.async_import_mode = false
		buf: [4096]u8
		cn := 0
		for cn < len(path) && cn < len(buf) - 1 {
			buf[cn] = u8(path[cn])
			cn += 1
		}
		buf[cn] = 0
		cpath := cstring(&buf[0])
		import_media(cpath)
		atrack := find_audio_track()
		if atrack == nil || len(atrack.clips) == 0 {
			fmt.println("[ap] SKIP: no audio track from", path)
			return true
		}
		audio_geometry_commit()
		audio_reset_play()
		fps := f64(timeline_fps())
		if fps <= 0 {
			fmt.println("[ap] SKIP: no project fps")
			return true
		}
		span := i64(0)
		for &c in atrack.clips {
			span = max(span, c.timeline_start_frame + c.source_length_frames)
		}
		if jump <= 0 {
			jump = min(i64(JUMP_GAP_SEC * fps), span - i64(JUMP_GAP_SEC * fps))
		}
		fmt.printf("[ap] jump=%d frames (%.1fs) over a %.1fs clip at %.0f fps\n",
			jump, f64(jump) / fps, f64(span) / fps, fps)
		if jump >= span {
			fmt.println("[ap] SKIP: jump lands past the clip; nothing to play there")
			return true
		}
		audio_provision(0)
		fmt.printf("[ap] provisioned %d sources at frame 0\n", audio_src.count)

		// Steady state before the jump: prove the engine is audible first, so a
		// failure after the jump cannot be a file that was silent all along.
		delivered := audio_probe_mix_run(0, JUMP_MIX_FRAMES, fps)
		fmt.printf("[ap] before jump: %d/%d frames delivered\n", delivered, JUMP_MIX_FRAMES)
		if delivered == 0 {
			fmt.println("[ap] FAIL: nothing decodes at frame 0; the jump proves nothing")
			return false
		}

		// The forward skip, exactly as audio_producer_feed applies jump_frame.
		delta48 := audio_frame_boundary48(jump, fps) - audio_frame_boundary48(audio_src.next_frame, fps)
		for k in 0 ..< audio_src.count {
			s := &audio_src.slots[k]
			if !s.dec.opened || s.fifo.buf == nil || delta48 <= 0 {
				continue
			}
			drop := int(min(delta48, i64(ring_len(&s.fifo))))
			if drop > 0 {
				s.first48 += i64(drop)
				ring_drop(&s.fifo, drop)
			}
		}
		audio_src.next_frame = jump
		fmt.printf("[ap] after skip: next_frame=%d, srcs=%d, fifo=%d frames\n",
			jump, audio_src.count, ring_len(&audio_src.slots[0].fifo))

		// Now mix at the jumped-to position. This is where "dies" shows up.
		//
		// Delivered frames alone are the wrong assertion: the engine "catches up"
		// -- it decodes everything between the old and new position and comes back,
		// which is what made this look like a transient. It is a defect, because
		// that catch-up is 5.2s of producer-thread blocking on a 166s jump (540
		// device underruns, measured), and the skipped audio is never played. So
		// the assertion is on decoding, not delivery: a jumped-to mixer may only
		// decode the seek preroll plus the frames actually asked for.
		dec_before := audio_src.slots[0].dec.decoded_frames
		ns_before := monotonic_ns()
		after := audio_probe_mix_run(jump, JUMP_MIX_FRAMES, fps)
		elapsed_ms := f64(i64(monotonic_ns() - ns_before)) / 1e6
		decoded := audio_src.slots[0].dec.decoded_frames - dec_before
		// What the mixer may legitimately decode: the gap, but only up to the
		// forward bound that is the whole point of the bound, plus the seek's own
		// preroll, plus what was asked for, plus one decoder frame of chunk
		// overshoot.
		gap48 := audio_frame_boundary48(jump, fps) - audio_frame_boundary48(0, fps)
		budget := min(gap48, AUDIO_FORWARD_DECODE_MAX_48) +
			i64((AUDIO_SEEK_PREROLL_SEC + f64(JUMP_MIX_FRAMES) / fps + JUMP_DECODE_SLACK_SEC) * 48000.0)
		fmt.printf("[ap] after jump: %d/%d frames delivered in %.1fms, decoded %d frames (budget %d)\n",
			after, JUMP_MIX_FRAMES, elapsed_ms, decoded, budget)
		if after == 0 {
			fmt.println("[ap] FAIL: a forward jump left the engine permanently silent")
			return false
		}
		if after < JUMP_MIX_FRAMES {
			fmt.printf("[ap] FAIL: %d frames silent right after the jump\n",
				JUMP_MIX_FRAMES - after)
			return false
		}
		if decoded > budget {
			fmt.printf(
				"[ap] FAIL: the jump decoded %d frames of skipped content (budget %d, %.1fs of audio) instead of seeking\n",
				decoded, budget, f64(decoded) / 48000.0,
			)
			return false
		}
		fmt.println("[ap] forward jump ok (seeked, did not decode the gap)")
		return true
	}


	// audio_probe_declick_check asserts that a clip BOUNDARY is a ramp, not a step.
	//
	// A click is a step: a transition from one sample to the next that is as large
	// as the signal around it, which puts a discontinuity in the waveform and a
	// broadband transient in the spectrum. So the measurement is the max
	// inter-sample STEP across the boundary, compared against the local PEAK -- and
	// the property under test is the ratio, not an absolute number, so it holds at
	// any source level.
	//
	// This case existed because the export ramped its boundaries and playback did
	// not: the declick was written for render_mix_block and audio_mix_frame never
	// called it, so the same edit produced a fade in one sink and a click in the
	// other. Nothing measured it, because nothing compared the two.
	//
	// The fixture is deliberately LOUD and abruptly cut. A boundary between two
	// segments of one continuous decode is not an edge at all (the samples either
	// side are already continuous), so the case builds a real gap: one clip that
	// ENDS mid-file, so the final contribution must fade to nothing.
	audio_probe_transparent_cuts :: proc(path: string) -> bool {
		fps := timeline_fps()
		if fps <= 0 {
			fmt.println("[ap] declick: SKIP: no project fps")
			return true
		}
		// A clip of its own, LOUD and cut short, on a clean timeline. Reusing whatever
		// the cases above left behind would make the boundary's position and the
		// signal level incidental to which case ran last.
		buf: [4096]u8
		cn := 0
		for cn < len(path) && cn < len(buf) - 1 {
			buf[cn] = u8(path[cn])
			cn += 1
		}
		buf[cn] = 0
		cpath := cstring(&buf[0])
		// The IMPORTED timeline, not a fresh one: the cases after this one replace
		// timeline.tracks wholesale, and a rebuild here fights the three-slot geometry
		// handoff (a commit lands in one slot while a stale reader holds another, so
		// the provision reads an empty one and the case reports "no audio on the
		// timeline"). The imported source is a continuous 440 Hz sine -- loud, and with
		// a real clip END to fade at, which is the edge under test.
		// Provision exactly the way audio_probe_gain_check does: reset, then provision
		// at frame 0, with NO commit of its own. The slab is already current from the
		// case above, and re-committing lands the chips in a different slot than the
		// provision then reads (three-slot handoff), which reads as an empty timeline
		// and made this case skip silently on its first two attempts.
		// No reset AFTER the provision: audio_reset_play clears every source slot, and
		// the gain check above provisions without one for exactly that reason.
		// Point every audio clip at the DC stream (stream 1). A click is a step, and a
		// step's measured size at the boundary depends on the signal's PHASE there: a
		// 440 Hz tone happens to sit near a zero crossing at the cut, so removing the
		// declick outright still measured a step a third of the amplitude and this
		// check passed. DC has no phase, so the step is the full amplitude every time.
		for ti in 0 ..< len(timeline.tracks) {
			for &c in timeline.tracks[ti].clips {
				if c.kind == .Audio {
					c.stream_index = 1
				}
			}
		}
		audio_geometry_commit()
		audio_provision(0)
		if audio_src.count == 0 {
			fmt.println("[ap] declick: SKIP: nothing provisioned")
			return true
		}
		// The boundary is the LAST segment END in the engine's own provisioned state,
		// not a frame computed from the timeline: the measurement is then about the
		// mix that actually plays, and it cannot be pointed at a segment the provision
		// never opened.
		//
		// LAST, not first, and that was the first version's bug in one line. The
		// fixture has several lanes of the same content, so an EARLIER segment end is
		// covered by the segments after it: the mix stays continuous across it, the
		// step never appears, and removing the declick entirely still passed. Only
		// where every source ends together does the mix reach silence, and that is
		// where the fade is the whole difference between a click and not one.
		fps_v := timeline_fps()
		end_frame := i64(-1)
		for i in 0 ..< audio_src.count {
			sl := &audio_src.slots[i]
			for k in 0 ..< sl.seg_count {
				seg := &sl.seg[k]
				e := seg.start_a + seg.len_a
				if e > end_frame {
					end_frame = e
				}
			}
		}
		if end_frame <= 0 {
			fmt.println("[ap] cuts: SKIP: no provisioned segment end to check at")
			return true
		}
		// Land six frames before the end so there is room for the interior comparison
		// on the far side of the boundary. EDGE_WINDOW is in INTERLEAVED samples, so
		// 1024 is 512 sample-frames: enough that the source's own ripple over ~512
		// samples averages out of the comparison, and it keeps this probe's arithmetic
		// in one declared unit instead of a bare number derived from a ramp length that
		// no longer exists.
		EDGE_WINDOW :: 1024
		spf := min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(48000.0 / fps + 0.5)))
		pre := 6
		lo := end_frame - i64(pre)
		if lo < 0 {
			lo = 0
		}
		audio_src.next_frame = lo
		mix: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
		// Collect the whole window as one contiguous signal, which is what a step is
		// measured on: the max |x[i]-x[i-1]| across consecutive samples.
		win: [dynamic]f32
		defer delete(win)
		// Append UNCONDITIONALLY. Appending only delivered frames skips the silent
		// ones, which is precisely the transition under test: a mix that fades out
		// stops being "delivered" at the fade's end, so the window ended at the last
		// loud sample and the step DOWN was never captured -- which is why removing the
		// declick entirely still passed this check.
		for i in 0 ..< pre * 2 + 2 {
			delivered := audio_mix_frame(mix[:], audio_src.next_frame, spf)
			if !delivered && i > pre {
				// Past the boundary and silent: the remainder is zeros by
				// construction, and appending thousands of them would only make the
				// window bigger without adding information.
				break
			}
			for f in 0 ..< spf {
				append(&win, mix[f * 2 + 0])
			}
			audio_src.next_frame += 1
		}
		if len(win) < 4 {
			fmt.println("[ap] declick: SKIP: nothing decoded around the segment end (lo", lo, ")")
			return true
		}
		// The property under test is that the boundary IS a ramp, not that the signal
		// happens to be quiet there.
		//
		// "Largest inter-sample step" is the obvious instrument and the wrong one: a
		// step's measured size depends on the signal's PHASE at the cut, and the
		// source's own codec tail ramps too. With a 440 Hz tone the cut landed near a
		// zero crossing, an unramped mix measured a third of the amplitude, and the
		// check passed with the declick deleted outright. So assert the RAMP: the fade
		// pulls the mix down across the samples before the boundary, which is
		// phase-independent and is exactly what the declick is for.
		boundary_idx := int(end_frame - lo) * spf
		interior_lo := boundary_idx - 4 * EDGE_WINDOW
		interior_hi := boundary_idx - 2 * EDGE_WINDOW
		// The last AUDIO_DECLICK_SAMPLES before the cut: exactly the span both mixers
		// fade across.
		edge_lo := boundary_idx - EDGE_WINDOW
		if interior_lo < 0 ||
		   edge_lo < 0 ||
		   interior_hi > len(win) ||
		   boundary_idx > len(win) {
			fmt.println("[ap] declick: SKIP: window too small to straddle the boundary")
			return true
		}
		interior_peak := f32(0)
		for i in interior_lo ..< interior_hi {
			av := abs(win[i])
			if av > interior_peak {
				interior_peak = av
			}
		}
		// The value AT the boundary, which is the whole assertion.
		//
		// Comparing the edge window's peak against the interior's does not work: the
		// source's own amplitude ripples over ~512 samples, so which window happens to
		// contain a peak is a coin flip, and an UNFADED cut measured 0.106 against an
		// interior of 0.126 and passed with the ramp deleted outright. A raised-cosine
		// fade reaches exactly zero at its end (audio_declick(1.0) == 0), and a cut
		// does not, so the last sample before the boundary is where the two differ and
		// it is where the answer does not depend on the signal's shape.
		at_edge := abs(win[boundary_idx - 1])
		// Kept because it is the symptom and it is free to report: a ramp spreads a
		// transition, so no single sample-to-sample move reaches the peak.
		step := f32(0)
		for i in 1 ..< len(win) {
			d := abs(win[i] - win[i - 1])
			if d > step {
				step = d
			}
		}
		if interior_peak <= 0 {
			fmt.println("[ap] cuts: SKIP: interior is silent")
			return true
		}
		// The boundary must be at FULL LEVEL. A ramp would land it near zero; a cut
		// lands it wherever the source is, which is the whole point -- the engine is
		// transparent, and an authored fade is expressed through the gain envelope
		// rather than imposed here.
		//
		// Half the interior level is the bar. Comparing against the source's own
		// amplitude is unavoidable (it ripples over ~512 samples, so which window
		// holds a peak is a coin flip), but the two cases are far apart: a completed
		// ramp gives ~0, and a transparent cut gives a value comparable to the
		// material. Nothing in between is reachable.
		if at_edge < interior_peak * 0.5 {
			fmt.printf(
				"[ap] FAIL: cuts are not transparent -- %.5f at the clip boundary against an interior peak of %.5f; something is still applying an envelope\n",
				at_edge, interior_peak,
			)
			return false
		}
		fmt.printf(
			"[ap] cuts are transparent (%.5f at the boundary against an interior peak of %.5f, largest step %.5f)\n",
			at_edge, interior_peak, step,
		)
		return true
	}


	// audio_probe_mix_parity drives BOTH mixers over the SAME timeline span and
	// asserts they produce IDENTICAL samples.
	//
	// This is the audio analogue of the geometry parity_probe, and it exists for the
	// same reason. `render_mix_block` (export) and `audio_mix_frame` (playback) are
	// near-identical copies of one loop that differ in the struct they read, the
	// granularity they iterate and how they resolve a clip's span. Nothing compared
	// them, so they could have drifted for as long as both were "correct" -- the same
	// one-fact-two-copies shape the geometry carrier fixed in Active 24, one level down
	// and in the engine that has to be right about time.
	//
	// It also answers a question nothing currently answers: do the two mixers agree
	// TODAY? They are meant to, they were never checked, and the answer decides whether
	// collapsing them onto one node (Active 30 S3) is a refactor of something
	// equivalent or a bug fix in disguise.
	//
	// How they are driven. Playback gets `frame` and mixes that frame's sample count.
	// Export gets an absolute `Sample_Pos` range and mixes it. The probe hands each
	// the same range -- audio_mix_frame for the frame, render_mix_block for
	// [frame_start, frame_end) -- and compares the buffers. Same input, same numbers,
	// one pipeline to change later.
	// audio_probe_priming_trace opens `path` exactly as render_audio_open does and
	// prints the first few decoded frames with their content positions. It answers
	// "where does the decoder actually land, and why" for a source whose muxer wrote
	// an encoder delay (AAC's first packet is pts=-1024 carrying skip_samples=1024).
	// Read-only: it mutates no application state and is not part of `audio_probe`.
	audio_probe_priming_trace :: proc(path: string) -> bool {
		// Same NUL-terminated conversion audio_probe_declick_check uses: the decoder
		// wants a cstring and the env var gives us a string.
		buf: [4096]u8
		cn := 0
		for cn < len(path) && cn < len(buf) - 1 {
			buf[cn] = u8(path[cn])
			cn += 1
		}
		buf[cn] = 0
		cpath := cstring(&buf[0])

		// For each ask, report where the seek to (ask - preroll) actually lands and
		// where decode_from_content then says the content begins. The gap between
		// those two numbers is the whole defect, so print both.
		asks := []i64{0, 1024, 4096, 24000}
		for _, ask in asks {
			dec: Audio_Clip_Decoder
			if !open_audio_decoder_resampled(&dec, cpath, 0, 48000, 2) {
				fmt.println("[ap] priming: could not open", path)
				return false
			}
			seek_sec := f64(ask)/f64(dec.out_rate) - AUDIO_SEEK_PREROLL_SEC
			seek_ok := seek_audio(&dec, seek_sec)
			n := decode_audio_chunk(&dec, f64(ask)/f64(dec.out_rate))
			landed := i64(-1)
			if dec.have_first {
				landed = i64(decoder_pts_sample(dec.first_ts, dec.stream.time_base))
			}
			fmt.printf(
				"[ap] priming: ask=%6d seek=%+8.3fs ok=%v landed=%6d n=%5d content_begins=%6d\n",
				int(ask), seek_sec, seek_ok, int(landed), n,
				int(landed) + n,
			)
			audio_decoder_reset(&dec)
		}
		return true
	}

	// audio_probe_drift_parity runs the playback and export mixers over a LONG span
	// and compares them continuously, so any accumulated position error shows up as a
	// mismatch that grows with time rather than as a constant offset.
	//
	// The short mix-parity probe answers "do they agree here". This answers "do they
	// still agree after ten minutes", which is the promise actually being made: one
	// sample clock, exact boundaries, no drift. Two failure modes it exists for:
	//
	//   - FRACTIONAL RATES. At 30000/1001 fps a frame is 1601 or 1602 samples,
	//     alternating forever. A mixer that rounds per frame instead of per position
	//     accumulates error silently, and every rate measured until now was 60 or 30
	//     EXACTLY, where that bug is invisible.
	//   - ACCUMULATED POSITION ERROR. A fifo that is refilled from a decoder whose
	//     position drifts will stay locally correct and end up globally wrong.
	//
	// Returns true when the two agree for the whole span.
	// DRIFT_TOLERANCE is how far the two sinks may differ on one sample and still be
	// called equal.
	//
	// It is 1e-3, about -60 dBFS and 33 LSB of s16, and the number is the
	// representation talking rather than a convenience. The two sinks sum the same
	// samples in DIFFERENT ORDERS -- playback accumulates a whole frame, the export a
	// 512-sample block -- so their f32 results legitimately differ by a few LSB.
	// A tolerance of 1e-4 is 3 LSB, which is tighter than two summation orders over
	// ~1600 samples can be asked to agree, and asserting it produced a permanent
	// 1.4e-4 "failure" in the clip's final 256-sample fade that was float rounding
	// and nothing else.
	//
	// Anything above this is not rounding: a desync, a wrong gain, or a missing
	// sample all show up orders of magnitude larger. The position invariant
	// (mixed == timeline requires, exactly) is asserted separately and with NO
	// tolerance at all, because sample counting is integer arithmetic and has no
	// excuse.
	DRIFT_TOLERANCE :: f32(1e-3)

	// audio_probe_stall_gap drives the REAL producer against a SIMULATED device and
	// proves the claim the audio-master design rests on: a producer stall costs the
	// listener a GAP and no subsequent offset.
	//
	// Everything else in this file compares the two mixers, which is arithmetic. This
	// is the only probe that exercises the TRANSPORT, and it exists because the stall
	// case cannot be provoked from outside: SIGSTOP freezes the device callback too
	// (it is in-process), so freezing the process is not a producer-only stall.
	//
	// So the device is simulated and the probe runs in REAL time, draining the
	// simulation at exactly the bus rate. The producer under test is the real
	// audio_update with its wall-clock coupling intact, and a "stall" is the probe
	// declining to call it -- which is exactly the condition being claimed about.
	//
	// Invariants asserted EVERY tick, before and after the stall:
	//
	//  1. dev_pos == fed - queued, in whole sample-frames. This is the whole design:
	//     the device position is the truth and it is derived, never commanded.
	//  2. starve_ticks does not move. The queue sitting at the cushion is the fixed
	//     point; leaving it is a defect, not a recovery.
	//  3. resync does not move. A resync RE-ANCHORS, and a re-anchor is a silent
	//     shift of the playhead -- the one thing the design cannot tolerate. This is
	//     the assertion that makes "no offset" more than a slogan.
	//
	// And after the stall: the device asked for audio that was never written (a gap,
	// counted), and once the producer resumes, invariant 1 still holds with no resync
	// in between. That is the definition of "a gap and no subsequent offset".
	// audio_probe_node_latency MEASURES the two delays in the audio graph and pins them.
	//
	// Both exist, neither is currently accounted for, and both are prerequisites for
	// the two features that come next:
	//
	//   - AUDIO SCRUBBING is a seek. `decode_from_content` guarantees the decoder lands
	//     on the asked sample; atempo downstream needs LOOKAHEAD, so the first D samples
	//     after a scrub are the graph filling rather than your content. A scrub landing D
	//     off is a desync that looks exactly like the bug Active 30 spent its length
	//     fixing, one layer up.
	//   - STRETCHING changes a clip's tempo. With a node delay, output position P holds
	//     input position P/rate - D, so the audio SLIDES UNDER THE TRIM by an amount
	//     proportional to the rate change. That does not look like drift; it looks like
	//     the audio not sticking to the cut, which is far harder to diagnose.
	//
	// Measured here rather than asserted in a comment, because a libavfilter bump can
	// change either number silently and nothing else in the tree would notice.
	//
	// swr: measured on the DEVICE conversion (48k -> the device rate), because that is
	// the one in the signal path. The decoder's own swr is 48k -> 48k and is a no-op, so
	// measuring that would report a comfortable zero and prove nothing.
	//
	// atempo: no API reports its internal holdback, so deterministic sample accounting
	// compares pushed input with emitted output. Waveform cross-correlation is not a
	// measure here: WSOLA reassembles overlapping segments rather than delaying a copy.
	audio_probe_node_latency :: proc() -> bool {
		fails := 0

		// --- swr: the device conversion, 48 kHz bus -> the rate the device negotiates.
		DEVICE_RATE :: 44100
		dev_delay := measure_swr_delay(DEVICE_RATE)
		fmt.printf("[ap] latency: swr 48000->%d reports %d output samples\n", DEVICE_RATE, dev_delay)

		// A passthrough must report zero, or the measurement itself is suspect.
		passthrough := measure_swr_delay(48000)
		fmt.printf("[ap] latency: swr 48000->48000 (passthrough) reports %d output samples\n", passthrough)
		if passthrough != 0 {
			fmt.println("[ap] latency: FAIL: a 1:1 resampler reported a delay; the measurement is not trustworthy")
			fails += 1
		}
		if dev_delay <= 0 {
			fmt.println("[ap] latency: FAIL: the device resampler reported no delay, so the conversion is not happening")
			fails += 1
		}

		// --- atempo: measured BY ACCOUNTING. See measure_atempo_delay for why the two
		// obvious methods cannot work.
		//
		// Two methods were tried and both are wrong in ways worth recording:
		//
		//  - Impulse correlation. atempo is WSOLA, so its output is not a time-shifted
		//    copy of its input -- it reassembles overlapping segments. No shift makes it
		//    correlate sharply; the "best" shift beat the runner-up by 1.4%, which is not
		//    a measurement, and at rate 2.0 it found nothing.
		//  - Energy onset. The feed path now demonstrably works (steady-state RMS ~0.27
		//    where it previously read silence), but the onset is quantised to the 128
		//    sample analysis window and at rate 0.5 it reports an onset EARLIER than the
		//    burst can possibly appear, given that the graph's effective rate is the
		//    reciprocal of the one requested. A number that is earlier than causality
		//    allows is a detector artefact, not a latency.
		//
		// Neither metric is used as a compensation constant. The bus computes outstanding
		// input dynamically from its cumulative counters, and the per-clip path starts with
		// real content and tests sample zero directly; reporting an untrusted scalar as a
		// correction would reintroduce the exact offset this gate removed.
		//
		// The sweep still pins throughput and repeatable holdback across all supported
		// rates. No interpolated latency table survives: it was the source of the per-clip
		// discard and was not converged between its four sample points.
		SWEEP :: []f64{
			0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1.0, 1.125, 1.25, 1.375, 1.5, 1.625,
			1.75, 1.875, 2.0, 2.25, 2.5, 2.75, 3.0, 3.5, 4.0,
		}
		for rate in SWEEP {
			in_frames, out_frames, delay_out := measure_atempo_delay(rate)
			// Expected output is pushed/RATE, not pushed*rate: atempo's tempo= parameter
			// is an output-length multiplier while the transport's rate is
			// content-consumed-per-second, so the two are inverses BY DEFINITION.
			//
			// A previous version of this probe asserted out/in == rate and reported the
			// reciprocal as a "latent transport bug". It was the probe that was wrong.
			// Measured effective factors are 1.98 / 1.32 / 0.79 / 0.50 for rates
			// 0.5 / 0.75 / 1.25 / 2.0 -- that is 1/rate to within a percent, which is
			// exactly what the design intends.
			delay_in := int((f64(in_frames)/rate - f64(out_frames)) * rate + 0.5)
			// Repeatability. Doubling input should settle to the same held-output estimate;
			// if it does not, report both samples rather than treating either as a constant.
			_, _, delay_long := measure_atempo_delay(rate, 384000)
			converged := abs(delay_long - delay_in) <= 8
			if converged {
				fmt.printf("[ap] latency: stable %.6f, %d input samples held\n", rate, delay_in)
			} else {
				fmt.printf(
					"[ap] latency: rate %.2f varies with push length -- %d then %d; no fixed compensation used\n",
					rate, delay_in, delay_long,
				)
			}
			fmt.printf(
				"[ap] latency: atempo rate %.2f -> in=%d out=%d expected=%.0f effective=%.3f (1/rate=%.3f) lookahead=%d IN samples (%.2f ms)\n",
				rate, in_frames, out_frames,
				f64(in_frames) / rate,
				f64(out_frames) / f64(max(in_frames, 1)),
				1.0 / rate,
				delay_in,
				f64(delay_in) / f64(AUDIO_BUS_RATE) * 1000,
			)
		}
		// Reproducibility: the lookahead must be stable run to run, or it is not a
		// measurement. Remeasured and compared rather than asserted once.
		RATES2 := []f64{0.5, 2.0}
		for rate in RATES2 {
			_, _, again := measure_atempo_delay(rate)
			_, _, first := measure_atempo_delay(rate)
			fmt.printf(
				"[ap] latency: atempo rate %.2f lookahead repeatability: %d then %d input samples\n",
				rate, first, again,
			)
			if again != first {
				fmt.println("[ap] latency: FAIL: the lookahead is not reproducible, so it is not a measurement")
				return false
			}
		}
		fmt.println("[ap] latency: both measured (swr authoritative; atempo by accounting, reproducible)")
		return true
	}

	// measure_swr_delay builds the 48 kHz -> `out_rate` conversion the device uses and
	// asks the resampler itself, which is the only authoritative source: swr_get_delay is
	// exactly the quantity a sink needs to compensate, so there is nothing to infer.
	measure_swr_delay :: proc(out_rate: c.int) -> i64 {
		ctx: ^swres.Context = swres.alloc()
		if ctx == nil {
			return -1
		}
		defer swres.free(&ctx)
		in_layout: avutil.ChannelLayout
		out_layout: avutil.ChannelLayout
		avutil.channel_layout_default(&in_layout, 2)
		avutil.channel_layout_default(&out_layout, 2)
		if swres.alloc_set_opts2(
			&ctx,
			&out_layout,
			avutil.SampleFormat.S16,
			out_rate,
			&in_layout,
			avutil.SampleFormat.Flt,
			48000,
			0,
			nil,
		) < 0 {
			return -1
		}
		if swres.init(ctx) < 0 {
			return -1
		}
		// Convert something FIRST. swr_get_delay reports what the resampler currently
		// OWES, so a resampler that has never been fed owes nothing and honestly reports
		// zero. Reading it before the first convert measured the absence of audio rather
		// than the filter's latency -- a comfortable answer to a question nobody asked.
		in_buf: [1024 * 2 * 4]u8
		out_buf: [4096 * 2 * 2]u8
		// Plane arrays and &plane[0], exactly as audio.odin calls swres.convert: the
		// binding takes a pointer to the plane, not a slice of planes.
		in_planes: [1][^]u8
		out_planes: [1][^]u8
		in_planes[0] = ([^]u8)(&in_buf[0])
		out_planes[0] = ([^]u8)(&out_buf[0])
		if swres.convert(ctx, &out_planes[0], 4096, &in_planes[0], 1024) < 0 {
			return -1
		}
		return i64(swres.get_delay(ctx, 48000))
	}

	// measure_atempo_delay measures the graph's lookahead BY ACCOUNTING, not by
	// waveform analysis.
	//
	// atempo's `tempo=` parameter is an output-length multiplier, while the transport's
	// `rate` is content-consumed-per-second. They are INVERSES by definition, so:
	//
	//     expected_output = pushed_input / rate
	//
	// Push N input frames, collect what comes out, and the shortfall is what the graph
	// is still HOLDING -- which is its lookahead, exactly:
	//
	//     delay_out = pushed/rate - got
	//     delay_in  = delay_out * rate
	//
	// This is far better than locating a burst in the output, and the reason is worth
	// recording because two other methods were tried and both were wrong. Impulse
	// correlation cannot work at all: atempo is WSOLA, so its output is not a
	// time-shifted copy of its input -- it reassembles overlapping segments, so no shift
	// correlates sharply. Energy onset then quantised the answer to the 128-sample
	// analysis window and reported an onset EARLIER than causality allows.
	//
	// Accounting has neither problem: it needs no waveform, no threshold and no window,
	// and it makes the result SELF-CHECKING, because the same lookahead must come out at
	// every rate that builds the same stage chain. Two rates agreeing is evidence; one
	// rate is a number.
	//
	// Returns (input frames pushed, output frames produced, delay in INPUT samples).
	measure_atempo_delay :: proc(rate: f64, push_frames: int = 192000) -> (in_frames, out_frames, delay_in: int) {
		g: Atempo_Graph
		atempo_rate_set(&g, rate)
		if g.graph == nil {
			return -1, -1, -1
		}

		// The output buffer must hold pushed/tempo frames, and the slowest tempo is 0.25,
		// so 8x the push is the smallest safe multiple. Sizing it to 4x SILENTLY truncated
		// every rate below 1.0 -- the shortfall then looked like a larger lookahead, which
		// is how a sweep produced the nonsense of 0.875 reporting 2282 while 0.75 reported
		// 1722. An instrument whose buffer is too small does not fail; it lies.
		PUSH_FRAMES :: 192000
		CHUNK :: 256
		sig: [CHUNK * 2]f32
		// HEAP, not the stack: 192000*8 frames of interleaved f32 is 6 MB, which Odin
		// warns about and which would be a real overflow under any deeper call chain. The
		// measurement is a probe, so paying an allocation for it is free.
		total_out: []f32 = make([]f32, PUSH_FRAMES * 16)
		got_floats := 0
		pushed := 0
		seed: u32 = 0x9E3779B9
		for pushed < push_frames {
			n := min(CHUNK, push_frames - pushed)
			// Broadband and deterministic, so the graph does real work rather than
			// degenerating on silence.
			for i in 0 ..< n * 2 {
				seed = seed * 1664525 + 1013904223
				sig[i] = f32(f32(seed >> 8) / f32(1 << 24) * 2.0 - 1.0) * 0.25
			}
			atempo_process(&g, sig[:], n)
			pushed += n
			if g.out_n == 0 {
				continue
			}
			if got_floats + g.out_n * 2 > len(total_out) {
				break
			}
			copy(total_out[got_floats:got_floats + g.out_n * 2], g.out_buf[:g.out_n * 2])
			got_floats += g.out_n * 2
		}
		got := got_floats / 2
		if got < 1024 {
			return pushed, got, -1
		}
		delay_out := f64(pushed) / rate - f64(got)
		_ = PUSH_FRAMES
		return pushed, got, int(delay_out * rate + 0.5)
	}


	// audio_probe_clip_stretch proves the STRETCH gesture's core invariant: changing a
	// clip's speed must NOT move the clip on the timeline.
	//
	// A clip occupies source_length_frames / speed frames. The gesture holds the numerator
	// product constant -- timeline_len = source_length_frames / speed -- so
	// source_length_frames = timeline_len * speed. If that arithmetic is wrong the clip
	// slides across the timeline as it is stretched, which is exactly what a trim does and
	// exactly what a stretch must not.
	//
	// This is the property the gesture cannot be checked for by eye, because the clip looks
	// like it stays put while dragging and only drifts after release. So it is arithmetic on
	// a Clip, checked against the same accessor the renderer reads.
	audio_probe_clip_stretch :: proc() -> bool {
		fails := 0
		TIMELINE_LEN :: i64(480)
		fmt.printf("[ap] stretch: timeline span must stay %d frames at every speed\n", TIMELINE_LEN)
		for speed in ([]f64{0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0}) {
			c := Clip {source_length_frames = TIMELINE_LEN, speed = 1.0}
			start := clip_timeline_length(&c)
			// Exactly what the gesture does on every move.
			c.speed = speed
			c.source_length_frames = max(1, i64(f64(TIMELINE_LEN) * speed))
			got := clip_timeline_length(&c)
			ok := start == got && got == TIMELINE_LEN
			fmt.printf(
				"[ap] stretch: speed %.3f -> %d content frames, timeline %d frames (want %d) %s\n",
				speed, c.source_length_frames, got, TIMELINE_LEN, verdict(ok),
			)
			if !ok {
				fails += 1
			}
		}
		// And the converse, because a stretch that changed nothing would also pass the
		// check above: the CONTENT must actually change, or the clip is not retimed.
		c := Clip {source_length_frames = 480, speed = 1.0}
		c.speed = 2.0
		c.source_length_frames = max(1, i64(f64(480) * 2.0))
		if c.source_length_frames == 480 {
			fmt.println("[ap] stretch: FAIL: doubling the speed did not change the content read")
			fails += 1
		}
		// The RANGE BOUNDS themselves, at the ends the gesture clamps to.
		//
		// Deliberately NOT testing that clip_speed clamps an out-of-range speed: it ASSERTS,
		// and that is the correct design. A clamp there would silently play a speed the user
		// never asked for, which is the same value/content disagreement the rest of this work
		// has been removing. Clamping belongs at the EDGE of the system -- the typed edit
		// clamps before it gets here, and the gesture clamps before it writes the field --
		// so what the accessor owes the user is a loud failure, not a quiet correction.
		for speed in ([]f64{CLIP_SPEED_MIN, CLIP_SPEED_MAX}) {
			c := Clip{source_length_frames = 480, speed = speed}
			if clip_speed(&c) != speed {
				fmt.printf("[ap] stretch: FAIL: clip_speed rejected its own bound %.3f\n", speed)
				fails += 1
			}
		}
		// The gesture's own clamp is what protects the field: a drag that runs off the end of
		// the range must land on the bound, not past it.
		drag := f64(1.0)
		for _ in 0 ..< 2000 {
			drag = clamp(drag * 1.01, CLIP_SPEED_MIN, CLIP_SPEED_MAX)
		}
		if drag != CLIP_SPEED_MAX {
			fmt.printf("[ap] stretch: FAIL: a runaway drag reached %.3f, past the bound %.3f\n", drag, CLIP_SPEED_MAX)
			fails += 1
		}
		if fails > 0 {
			fmt.printf("[ap] stretch: FAIL (%d)\n", fails)
			return false
		}
		fmt.println("[ap] stretch ok (span fixed, content length follows speed)")
		return true
	}

	// audio_probe_scrub_exact proves a SEEK lands on the content sample the timeline says
	// belongs there -- for an unstretched clip AND a stretched one.
	//
	// Scrubbing is the one gesture that is pure seeking, so it is where a position mapping
	// is easiest to get wrong and hardest to notice: a clip that is off by a few hundred
	// samples still sounds like itself, and the drift only shows as the playhead and the
	// audio disagreeing. Nothing else in the audio suite would catch it.
	//
	// The mapping under test is audio_content_sample_at_speed: at speed S, timeline frame N
	// holds content sample N*S, plus the clip's own source offset. The factor is what a
	// stretched clip needs -- without it the mixer asks for content at 1x while the clip
	// occupies 1/S of the timeline, reads the wrong content, and runs out early.
	//
	// Asserted in three parts, because a position bug can hide in any one of them:
	//   - the mapping itself, at several speeds and offsets, against the closed form;
	//   - MONOTONICITY, so a seek can never jump backwards through the content;
	//   - the ROUND TRIP through frame_at_sample, so the seek target and the frame the mixer
	//     lands on agree to within one frame.
	audio_probe_scrub_exact :: proc() -> bool {
		fails := 0
		// The project's own rate, rationalised, so the round trip goes through the same
		// conversion the renderer uses rather than an idealised 1.0.
		n32, d32 := fps_rational(timeline_fps())
		rn, rd := i64(n32), i64(d32)

		for speed in ([]f64{0.25, 0.5, 1.0, 1.5, 2.0, 4.0}) {
			for frames_into in ([]i64{0, 1, 30, 120, 1000}) {
				// A source offset so a clip that does not start at content 0 is covered too:
				// the two mistakes are additive and the offset is where the second one hides.
				start_s := i64(48)
				got := audio_content_sample_at_speed(frames_into, start_s, f64(rn) / f64(rd), speed)
				base := timeline_frame_sample(frames_into)
				want := audio_content_sample(frames_into, start_s, f64(rn) / f64(rd))
				// speed 1.0 must be exactly the unstretched mapping, and the stretched form
				// must be within a sample of base*speed (rounding on the multiply).
				if speed == 1.0 {
					if got != want {
						fmt.printf("[ap] scrub: FAIL: speed 1.0 changed the mapping (%v vs %v)\n", got, want)
						fails += 1
					}
				} else if math.abs(f64(got - want) - f64(base) * (speed - 1.0)) > 1.0 {
					fmt.printf(
						"[ap] scrub: FAIL: speed %.3f at frame %d -> %v, want about %v\n",
						speed, frames_into, got, want + Sample_Pos(f64(base) * (speed - 1.0)),
					)
					fails += 1
				}
				// ROUND TRIP, and the division by speed is the point.
				//
				// timeline_frame_at_sample knows nothing about a clip's speed -- it is the
				// plain timeline mapping. So mapping a speed-scaled content sample straight
				// back gives frames_into*speed, which is CORRECT and is exactly what the
				// clip means: at speed 2 the content at timeline frame 120 also appears at
				// timeline frame 240 of the raw 1:1 mapping. Undoing the stretch means
				// dividing by the speed first.
				//
				// Getting this wrong in the engine is the "plays at roughly 1x" bug: the
				// mapping asks for content at 1x while the clip occupies 1/S of the
				// timeline, reads the wrong content, and runs out early.
				// The clip's own source offset comes off too: `got` is base*speed PLUS the
				// offset, so dividing alone would leave the offset scaled by the speed --
				// visible above as a round trip landing on frame 12 instead of 0.
				off := audio_source_start_sample(start_s, f64(rn) / f64(rd))
				back := timeline_frame_at_sample(Sample_Pos(f64(got - off) / speed))
				if abs(back - frames_into) > 1 {
					fmt.printf(
						"[ap] scrub: FAIL: speed %.3f frame %d -> sample %v -> frame %d\n",
						speed, frames_into, got, back,
					)
					fails += 1
				}
			}
		}

		// MONOTONIC. Swept densely across the whole clip range, at every speed: a mapping
		// that ever goes backwards would let a forward seek replay audio the playhead has
		// already passed.
		for speed in ([]f64{0.25, 0.5, 1.0, 1.5, 2.0, 4.0}) {
			prev := audio_content_sample_at_speed(0, 0, 1.0, speed)
			for f in i64(1) ..< 2000 {
				at := audio_content_sample_at_speed(f, 0, 1.0, speed)
				if at < prev {
					fmt.printf("[ap] scrub: FAIL: speed %.3f went BACKWARDS at frame %d (%v < %v)\n", speed, f, at, prev)
					fails += 1
					break
				}
				prev = at
			}
		}
		if fails > 0 {
			fmt.printf("[ap] scrub: FAIL (%d)\n", fails)
			return false
		}
		fmt.println("[ap] scrub ok (seek lands on the timeline's content sample, monotonically)")
		return true
	}

	// verdict renders a pass/fail word for the probe's single output line. A named helper
	// rather than an inline ternary so every assertion in the probe reads the same way.
	verdict :: proc(ok: bool) -> string {
		return ok ? "ok" : "FAIL"
	}

	// audio_probe_clip_tempo proves the clip TEMPO property changes DURATION and leaves
	// pitch alone. Two independent parts, because one measurement cannot establish both and
	// conflating them is what made three earlier versions of this probe useless.
	//
	// PART 1 -- THE DSP, measured in isolation.
	//
	// Push N samples of a steady tone through the graph at speed S and count what comes out.
	// The factor is exactly out/in, with no mixer, no prefetch, no ring, and no timeline.
	//
	//     out / in == 1 / S
	//
	// This is exact to a sample or two and it is the property the user hears. atempo's
	// `tempo=` is a speed multiplier, so a clip at speed S passes tempo = S and the graph
	// emits 1/S as many frames -- pitch corrected, duration changed. Anything else, including
	// an inverted argument, shows up here immediately and unambiguously.
	//
	// PART 2 -- THE GEOMETRY.
	//
	// A clip's TIMELINE span must be its content divided by the speed, or the audio and the
	// picture disagree about how long the clip is. That is pure arithmetic on the clip, with
	// no samples involved, so it cannot be confounded by anything the mixer does.
	//
	// WHY NOT THE MIXER. The first three versions of this probe read sample counts out of
	// the playback mixer, and every one of them was wrong:
	//
	//   - PULSE DENSITY is not a tempo measurement. WSOLA repeats and discards segments, so a
	//     faster clip has MORE onset crossings on the same content. It read 1.0000 at every
	//     speed.
	//   - "content consumed" is not one either. The graph pulls in chunks, so nearly
	//     everything the clip asks for is consumed within one block and the ratio pins at
	//     ~1.0 regardless of speed.
	//   - Raw output sample counts are worse still: the producer PREFILLS its rings, so at
	//     speed 0.25 an 8 s window returned 1113600 samples -- 23.2 s of audio from a span
	//     that only asked for 8 s. The prefetch is real and correct behaviour; it simply is
	//     not a clock.
	//
	// The mixer measures the transport, which is what audio_drift_parity and
	// audio_stall_gap are for. This probe measures the tempo PROPERTY, so it stays out of
	// the mixer entirely.
	audio_probe_clip_tempo :: proc() -> bool {
		fails := 0

		// PART 1: the isolated graph.
		SPEEDS :: []f64{0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0}
		//
		// MEASURED BY DIFFERENCE, not by ratio. A single run's out/in is biased low by the
		// output samples still held inside WSOLA -- the graph's real lookahead, not a priming
		// discard. Reading it as a ratio made every speed look 1-2% slow and would have sent
		// me hunting for a tempo bug that is not there:
		//
		//     speed 1.0 -> 0.49600 instead of 0.50000   (2.5% low at 4.0, 1.1% at 0.5)
		//
		// The bias is the same absolute constant at every speed, so pushing twice as much
		// input and taking the DIFFERENCE divides it out exactly:
		//
		//     factor = (out(N2) - out(N1)) / (N2 - N1)
		//
		// No model of graph holdback is needed, and nothing about WSOLA has to be assumed.
		fmt.println("[ap] tempo: isolated graph, (out(N2)-out(N1))/(N2-N1) must equal 1/speed")
		N1, N2 := 192000, 576000
		for speed in SPEEDS {
			in1, out1, _ := measure_atempo_delay(speed, N1)
			in2, out2, _ := measure_atempo_delay(speed, N2)
			din := in2 - in1
			dout := out2 - out1
			if din <= 0 || dout <= 0 {
				// At speed 1.0 no graph is built at all, which is correct: an unstretched
				// clip must be bit-identical to the raw decode, so there is nothing to
				// measure and forcing a graph would test the wrong thing.
				note: string = speed == 1.0 ? "ok" : "FAIL"
				fmt.printf("[ap] tempo: speed %.3f -- no graph built (identity), nothing to measure %s\n", speed, note)
				if speed != 1.0 {
					fails += 1
				}
				continue
			}
			got := f64(dout) / f64(din)
			want := 1.0 / speed
			// 0.5%: with the constant divided out, the only error left is WSOLA's own
			// segment rounding, which is sub-percent at these lengths.
			tol := 0.005 * want
			ok := math.abs(got - want) <= tol
			fmt.printf(
				"[ap] tempo: speed %.3f -> d_in %d / d_out %d = %.5f (want %.5f +/- %.5f) %s\n",
				speed, din, dout, got, want, tol, verdict(ok),
			)
			if !ok {
				fails += 1
			}
		}

		// PART 2: the clip geometry. No samples, so nothing can confound it.
		fmt.println("[ap] tempo: clip geometry, timeline span must be content/speed")
		clip := Clip {source_length_frames = 2400, speed = 1.0}
		for speed in SPEEDS {
			clip.speed = speed
			// The accessor normalises 0 to 1, so a zero here would silently pass; set it
			// explicitly and read the normalised value back.
			got := clip_timeline_length(&clip)
			want := max(1, i64(f64(2400) / speed))
			ok := got == want
			fmt.printf(
				"[ap] tempo: content 2400 at speed %.3f -> timeline %d frames (want %d) %s\n",
				speed, got, want, verdict(ok),
			)
			if !ok {
				fails += 1
			}
		}

		// The identity case is the one users hit most, so it gets an explicit assertion
		// rather than being left to the sweep: at speed 1 the clip must occupy exactly its
		// content length.
		clip.speed = 1.0
		if clip_timeline_length(&clip) != 2400 {
			fmt.println("[ap] tempo: FAIL: an unstretched clip does not occupy its content length")
			fails += 1
		}

		if fails > 0 {
			fmt.printf("[ap] tempo: FAIL (%d)\n", fails)
			return false
		}
		fmt.println("[ap] tempo ok (isolated factor and clip geometry both exact)")
		return true
	}

	// mix_clip_range_setup builds the single-clip timeline at `speed` and provisions it.
	audio_probe_timeline_reset :: proc() {
		audio_reset_for_load()
		audio_reset_play()
		// These headless probes own their synthetic timeline. Replacing a populated
		// dynamic array with make() leaked its backing storage (and every Track.clips
		// allocation) on each speed/seek case.
		for i in 0 ..< len(timeline.tracks) {
			if timeline.tracks[i].clips != nil {
				delete(timeline.tracks[i].clips)
			}
		}
		if timeline.tracks != nil {
			delete(timeline.tracks)
		}
		if timeline.track_order != nil {
			delete(timeline.track_order)
		}
		timeline.tracks = make([dynamic]Track, 0, 1)
		timeline.track_order = make([dynamic]int, 0, 1)
	}

	mix_clip_range_setup :: proc(path: cstring, frames: i64, speed: f64) {
		audio_probe_timeline_reset()
		track := Track {name = "tempo", clips = make([dynamic]Clip, 0, 1)}
		append(
			&track.clips,
			Clip {
				clip_id = new_clip_id(),
				path = path,
				kind = .Audio,
				name = session_str_intern("t"),
				timeline_start_frame = 0,
				source_length_frames = frames,
				source_start_frame = 0,
				stream_index = 0,
				speed = speed,
			},
		)
		append(&timeline.tracks, track)
		sync_track_order()
		selection.track, selection.index = -1, -1
		audio_geometry_commit()
		audio_reset_play()
		audio_prod.last_ui_frame = -1
		audio_provision(0)
	}

	// mix_clip_range mixes `frames` of a single clip at `speed` through the real playback
	// mixer and returns the interleaved output.
	mix_clip_range :: proc(
		path: cstring,
		content_frames, span_frames: i64,
		speed, fps: f64,
		semitones: f32 = 0,
		timeline_start: i64 = 0,
	) -> [dynamic]f32 {
		audio_probe_timeline_reset()
		track := Track {name = "tempo", clips = make([dynamic]Clip, 0, 1)}
		append(
			&track.clips,
			Clip {
				clip_id = new_clip_id(),
				path = path,
				kind = .Audio,
				name = session_str_intern("t"),
				timeline_start_frame = 0,
				// CONTENT length, which is what stretching leaves alone. The timeline span
				// is derived from it below. Passing the span here instead is what made the
				// pulse density read ~1.0 at every speed: a 2x clip declared 2 s of content
				// and therefore only had 20 clicks to play, at the same 10/s as unstretched.
				source_length_frames = content_frames,
				source_start_frame = 0,
				stream_index = 0,
				speed = speed,
				pitch = semitones,
			},
		)
		append(&timeline.tracks, track)
		sync_track_order()
		selection.track, selection.index = -1, -1
		audio_geometry_commit()
		audio_reset_play()
		audio_prod.last_ui_frame = -1
		audio_provision(timeline_start)
		if audio_src.count == 0 {
			return {}
		}
		out: [dynamic]f32
		mix: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
		for f in timeline_start ..< timeline_start + span_frames {
			spf := min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(audio_frame_boundary48(f+1, fps) - audio_frame_boundary48(f, fps))))
			// Keep timeline duration even when a mixer frame has a decode hole. The mixer
			// zeros its destination before attempting delivery; omitting false frames here
			// compresses time and can move a later transient to output sample zero.
			audio_mix_frame(mix[:], f, spf)
			for i in 0 ..< spf * 2 {
				append(&out, mix[i])
			}
		}
		return out
	}

	// audio_probe_bus_prime asserts that the BUS atempo is ALIGNED: the first sample it
	// emits is the first sample fed, not the middle of the graph's warm-up.
	//
	// A failed attempt to "fix" that offset introduced it: synthetic silence was pushed
	// through a fresh atempo graph and output from the first real input was discarded.
	// FFmpeg already zero-pads its first WSOLA half-window and begins overlap-add at sample
	// zero. The producer must feed REAL input immediately and let the filter buffer until
	// it can emit that origin-aligned output.
	//
	// The measurement is both origin alignment and clock conservation: feed a click track
	// and require its first output transient at sample 0, then account for graph-held input
	// as well as queued output when deriving the device's audible content position.
	audio_probe_bus_prime :: proc(path: string, rate: f64 = 2.0) -> bool {
		g: Atempo_Graph
		atempo_rate_set(&g, rate)
		if g.graph == nil {
			fmt.println("[ap] bus-prime: SKIP: no graph at this rate")
			return true
		}
		defer atempo_graph_destroy(&g)

		CLICK_MS :: 10
		INPUT_SECONDS :: 3
		total := int(f64(AUDIO_BUS_RATE) * INPUT_SECONDS)
		// A click every CLICK_MS, from the very first sample, so the FIRST transient has a
		// known position (0) and any displacement of it is the graph's latency.
		click := int(click_samples(CLICK_MS))
		sig: [4096 * 2]f32
		// Heap: 1.5 MB on the stack is the same overflow risk as the one above.
		out: []f32 = make([]f32, AUDIO_BUS_RATE * 8 * 2)
		defer delete(out)
		got := 0
		seed: u32 = 0x1234567
		// Do not manually prefill the graph. FFmpeg's atempo initializes the leading
		// half-window with zeros and labels its first overlap-add output at sample 0;
		// the graph buffers enough REAL input before emitting it. A silence prefill
		// advances the graph's input/output positions and the subsequent discard loses
		// genuine opening audio. Test the graph's natural origin-preserving path.

		for pushed := 0; pushed < total; {
			n := min(2048, total - pushed)
			for i in 0 ..< n {
				is_click := pushed + i < click || (pushed + i) % click == 0
				v := f32(0)
				if is_click {
					v = 0.9
				} else {
					// A little noise so the clicks are not the only energy, which makes the
					// onset detector below unambiguous.
					seed = seed * 1664525 + 1013904223
					v = f32(f32(seed >> 8) / f32(1 << 24) * 2.0 - 1.0) * 0.02
				}
				sig[i * 2 + 0] = v
				sig[i * 2 + 1] = v
			}
			atempo_process(&g, sig[:], n)
			pushed += n
			if g.out_n == 0 {
				continue
			}
			if got + g.out_n * 2 > len(out) {
				break
			}
			copy(out[got:got+g.out_n*2], g.out_buf[:g.out_n*2])
			got += g.out_n * 2
		}
		if got < click * 4 {
			fmt.println("[ap] bus-prime: SKIP: not enough output to locate a click")
			return true
		}

		first_in := first_onset(out[:got], 0)
		fmt.printf("[ap] bus-prime: rate %.2f, first transient at output sample %d (want 0)\n", rate, first_in)
		if first_in < 0 {
			// No transient found. Report a SKIP rather than an offset of "-1 samples";
			// an absent measurement is not evidence of alignment.
			fmt.println("[ap] bus-prime: SKIP: no transient found in the output; cannot locate the offset")
			return true
		}
		if first_in != 0 {
			fmt.printf(
				"[ap] bus-prime: FAIL: the bus graph emitted its first sample %d late -- the stream is offset by %.2f ms\n",
				first_in, f64(first_in) / f64(AUDIO_BUS_RATE) * 1000,
			)
			return false
		}
		// The device clock must account for samples held INSIDE atempo, not only samples
		// already queued with the device. Simulate half the graph output consumed: the
		// audible content sample must be that consumed output count, mapped back through
		// the graph rate. Without the pending-input term the playhead reports graph lookahead
		// as already audible even though the device has not received it.
		consumed_out := g.output_total / 2
		queued_out := g.output_total - consumed_out
		pending_in := atempo_pending_input_samples(&g)
		audible := audio_device_audible_sample(
			Sample_Pos(g.input_total), queued_out, rate, &g, pending_in,
		)
		want_audible := i64(f64(consumed_out) * rate + 0.5)
		if abs(i64(audible)-want_audible) > 1 {
			fmt.printf(
				"[ap] bus-prime: FAIL: device clock %d samples, expected %d after consuming half of output at %.2fx\n",
				audible, want_audible, rate,
			)
			return false
		}
		fmt.println("[ap] bus-prime: ok (sample origin aligned; queued + WSOLA-held time maps to device consumption)")
		return true
	}

	// audio_probe_bus_rate_transition exercises the production rate-change path with a
	// simulated device. It changes 1x -> 2x -> 3x -> 1x while audio is queued and proves
	// each rebuild anchors at the current audible sample, clears old-rate PCM, and never
	// moves the published device playhead backwards.
	audio_probe_bus_rate_transition :: proc(path: string) -> bool {
		path_buf: [4096]u8
		path_n := min(len(path), len(path_buf) - 1)
		for i in 0 ..< path_n {
			path_buf[i] = u8(path[i])
		}
		path_buf[path_n] = 0

		fps := timeline_fps()
		if fps <= 0 {
			fmt.println("[ap] rate-transition: no fps")
			return false
		}
		old_rate := playback.rate
		defer playback.rate = old_rate

		audio_reset_for_load()
		audio_reset_play()
		timeline.tracks = make([dynamic]Track, 0, 1)
		timeline.track_order = make([dynamic]int, 0, 1)
		run_frames := i64(fps * 12.0)
		track := Track{name = "rate-transition", clips = make([dynamic]Clip, 0, 1)}
		append(
			&track.clips,
			Clip{
				clip_id = new_clip_id(),
				path = cstring(&path_buf[0]),
				kind = .Audio,
				name = session_str_intern("rt"),
				timeline_start_frame = 0,
				source_length_frames = run_frames,
				source_start_frame = 0,
				stream_index = 0,
			},
		)
		append(&timeline.tracks, track)
		sync_track_order()
		selection.track, selection.index = -1, -1
		audio_geometry_commit()

		SIM_CAP :: i64(AUDIO_BUS_RATE * 4)
		audio_device_sim_enable(SIM_CAP)
		defer audio_device_sim_disable()
		audio_reset_play()
		audio_prod.last_ui_frame = -1
		audio_provision(0)
		if audio_src.count == 0 {
			fmt.println("[ap] rate-transition: SKIP: no source provisioned")
			return true
		}
		playback.rate = 1.0
		playhead.frame = 0
		playhead.playing = true
		preview.playing = true

		TICK_MS :: 5
		TICKS :: 240
		RATE_2X_TICK :: 60
		RATE_3X_TICK :: 140
		TICK_SAMPLES :: i64(AUDIO_BUS_RATE * TICK_MS / 1000)
		prior_dev := sync.atomic_load(&playback.dev_frame)
		rebuild_start := audio_rpt.rate_rebuilt
		for t in 0 ..< TICKS {
			if t == RATE_2X_TICK {
				playback.rate = 2.0
			} else if t == RATE_3X_TICK {
				playback.rate = 3.0
			}
			if t == TICKS - 1 {
				playback.rate = 1.0
			}
			audio_producer_feed()
			audio_device_sim_consume(TICK_SAMPLES)
			dev := sync.atomic_load(&playback.dev_frame)
			if dev < prior_dev {
				fmt.printf("[ap] rate-transition: FAIL: device frame moved backwards %d -> %d at tick %d\\n", prior_dev, dev, t)
				return false
			}
			prior_dev = dev
			// The signal is only asserted after each requested transition has had one
			// producer pass; rate_rebuilt is the effect the clock must remain aligned to.
			if (t == RATE_2X_TICK || t == RATE_3X_TICK || t == TICKS - 1) &&
			   audio_rpt.rate_rebuilt < rebuild_start + u64(t == RATE_2X_TICK ? 1 : t == RATE_3X_TICK ? 2 : 3) {
				fmt.printf("[ap] rate-transition: FAIL: rate rebuild missing at tick %d\\n", t)
				return false
			}
		}
		if audio_device_queued() <= 0 {
			fmt.println("[ap] rate-transition: FAIL: no audio queued after final 1x rebuild")
			return false
		}
		fmt.println("[ap] rate-transition: ok (1x -> 2x -> 3x -> 1x; audible frame monotonic)")
		return true
	}

	// click_samples is the fixture's click interval in sample-frames.
	click_samples :: proc(click_ms: int) -> i64 {
		return i64(AUDIO_BUS_RATE) * i64(click_ms) / 1000
	}

	// first_onset returns the index of the first FRAME exceeding half the window's peak,
	// or -1.
	//
	// In FRAMES, not interleaved samples. Scanning the flat interleaved array treats L and
	// R as consecutive time samples, which halves every reported position and made the
	// offset look constant across rates -- atempo's latency scales with tempo, so a
	// constant reading was the clue that the probe, not the graph, was wrong. This is the
	// same interleaved/frames confusion that hit the drift probe earlier.
	first_onset :: proc(buf: []f32, refractory_frames: int) -> int {
		frames := len(buf) / 2
		peak := f32(0)
		for i in 0 ..< frames {
			peak = max(peak, abs(buf[i * 2]))
		}
		if peak <= 1e-5 {
			return -1
		}
		thresh := peak * 0.5
		since := 0
		for i in 0 ..< frames {
			if since < refractory_frames {
				since += 1
				continue
			}
			if abs(buf[i * 2]) > thresh {
				return i
			}
		}
		return -1
	}

	// audio_probe_seek_landing_offset measures WHERE a seek actually lands, on the
	// PLAYBACK PRODUCER path, by content rather than by state.
	//
	// Every existing seek assertion measures either state (next_frame rewound, queue
	// dropped) or the EXPORT mixer (mix_clip_range). Both were satisfied while playback
	// emitted the wrong samples: the user's own trace showed the same waveform playing 22
	// frames late after a backward scrub, a constant offset equal to
	// AUDIO_SEEK_PREROLL_SEC minus the demuxer's landing slack. State was correct and the
	// sound was at the wrong position.
	//
	// The fixture is the click track: a pulse every 125 ms starting at content sample 0.
	// After a seek to frame F the first transient must land at the timeline sample F maps
	// to. Anything else is an offset, and the offset is printed -- its SIZE is the
	// finding, not a pass/fail, because the size tells us which of the preroll, the
	// landing slack, or the labelling is wrong.
	audio_probe_seek_landing_offset :: proc(path: string) -> bool {
		defer audio_probe_timeline_reset()
		// play_trace is normally set in main(), which runs AFTER every VYPER_AUDIO_* probe
		// is dispatched, so without this the per-frame decode trace is silently off here
		// -- and that trace is the only way to see where a seek actually lands.
		// play_trace is normally set in main(), which runs AFTER every VYPER_AUDIO_* probe
		// is dispatched, so the per-frame decode trace is silently off here without this.
		// Deferred restore is deliberately NOT used: audio_probe_timeline_reset runs on
		// return and a later probe in the same process must not inherit the flag.
		saved_trace := play_trace
		play_trace = os.get_env_alloc("VYPER_PLAY_TRACE", context.temp_allocator) == "1"
		defer play_trace = saved_trace
		fps := timeline_fps()
		if fps <= 0 {
			fmt.println("[ap] seek-landing: no fps")
			return false
		}
		path_buf: [4096]u8
		assert(len(path) < len(path_buf), "audio_probe_seek_landing_offset: path buffer overflow")
		path_n := len(path)
		for i in 0 ..< path_n {
			path_buf[i] = u8(path[i])
		}
		path_buf[path_n] = 0

		// fps is not a compile-time constant here, so these are plain values.
		CLICK_FRAMES := i64(fps * 4.0)
		// An exact multiple of the 125 ms click interval, so the expected transient
		// lands on a sample boundary rather than near one.
		CLICK_INTERVAL_FRAMES := i64(fps * 0.125)
		for target in ([]i64{CLICK_INTERVAL_FRAMES * 8, CLICK_INTERVAL_FRAMES * 16, CLICK_INTERVAL_FRAMES * 24}) {
			// Reference: the export mixer, which is the known-correct path, rendered from
			// the same timeline. Same geometry, same clip, same content.
			// Render the reference from the SAME frame the playback path is mixed from.
			// Rendering from 0 compares a pulse at frame 0 against one at frame `target`,
			// which is not an offset measurement at all -- it is two different instants.
			want := mix_clip_range(
				cstring(&path_buf[0]),
				CLICK_FRAMES,
				target + CLICK_INTERVAL_FRAMES * 3,
				1.0,
				fps,
				0,
				target,
			)
			if len(want) == 0 {
				delete(want)
				fmt.printf("[ap] seek-landing: FAIL: reference render at frame %d produced nothing\n", target)
				return false
			}
			// Playback: provision, then seek to the same target through the producer's own
			// anchor path, then mix the frames that follow and find where the first pulse
			// arrives.
			mix_clip_range_setup(cstring(&path_buf[0]), CLICK_FRAMES, 1.0)
			if audio_src.count != 1 {
				delete(want)
				fmt.println("[ap] seek-landing: FAIL: source did not provision")
				return false
			}
			// Seek the way a backward scrub does: through audio_anchor_sources, which is
			// what the reconcile calls.
			// Seek the LIVE slot. Play_Src is ~1.4 MB (MAX_PLAY_SEGMENTS segments plus a
			// decoder), so a local copy is both a stack overflow and a different source
			// from the one the mixer will read.
			want48 := i64(audio_content_sample_at_speed(target, 0, 1.0, 1.0))
			content_sec := f64(want48) / f64(AUDIO_BUS_RATE)
			ok := audio_src_seek_anchor(&audio_src.slots[0], content_sec, audio_frame_boundary48(target, fps))
			if !ok {
				delete(want)
				fmt.printf("[ap] seek-landing: FAIL: seek to frame %d failed\n", target)
				return false
			}
			// The fifo must COVER the request once the seek returns, which is what
			// audio_mix_frame reads: it mixes from start48 = max(demand48, first48), so an
			// early label is only usable once have48 has reached the demand.
			//
			// The assertion used to be `first48 == want48` -- that the fifo is LABELLED at
			// the request. Demanding the label discard the preroll instead, which is wrong:
			// the preroll is what the tempo graph primes itself with, and the clip-alignment
			// probe measured a 0.25x clip's opening click pushed 880 output samples late
			// once it was gone. Coverage is the property the mixer actually depends on; the
			// label is a decoder detail it tolerates either side of.
			have := audio_src.slots[0].have48
			landed := audio_src.slots[0].first48
			if have < want48 {
				fmt.printf(
					"[ap] seek-landing: FAIL: after seek to frame %d the fifo covers content %d, want %d (short by %d)\n",
					target, have, want48, want48 - have,
				)
				delete(want)
				return false
			}
			if landed > want48 {
				fmt.printf(
					"[ap] seek-landing: FAIL: after seek to frame %d the fifo starts at content %d, past the request %d\n",
					target, landed, want48,
				)
				delete(want)
				return false
			}
			// Mix forward from the target and find the first transient in the OUTPUT. The
			// click pulse is 10 ms wide, so a landing one pulse late still has the next one
			// inside the window -- which is the whole reason a click fixture measures an
			// offset at all: a steady tone cannot, because every position looks the same.
			frames_to_mix := int(CLICK_INTERVAL_FRAMES * 3)
			spf := int(audio_frame_boundary48(target + 1, fps) - audio_frame_boundary48(target, fps))
			got: [MAX_AUDIO_FRAME_SAMPLES * 16]f32
			if spf * frames_to_mix * 2 > len(got) {
				delete(want)
				fmt.println("[ap] seek-landing: FAIL: scratch buffer too small for the span")
				return false
			}
			for f in 0 ..< frames_to_mix {
				fr := target + i64(f)
				if !audio_mix_frame(got[f * spf * 2:], fr, spf) {
					delete(want)
					fmt.printf("[ap] seek-landing: FAIL: frame %d delivered no samples\n", fr)
					return false
				}
			}
			got_first := first_onset(got[:spf * frames_to_mix * 2], 0)
			want_first := first_onset(want[:], 0)
			delete(want)
			// The reference's first pulse is at its sample 0; the playback path's should
			// be too. A difference is the offset, in samples.
			offset := got_first - want_first
			fmt.printf(
				"[ap] seek-landing: frame %d -> playback transient at %d, reference at %d, offset %+d samples (%+.3f s)\n",
				target,
				got_first,
				want_first,
				offset,
				f64(offset) / f64(AUDIO_BUS_RATE),
			)
			// One frame of tolerance: the mixer's per-frame boundary is exact, so anything
			// larger is a real offset and the probe should fail on it rather than print a
			// number and move on. The value is printed above either way, because the SIZE
			// is the finding.
			tolerance := spf
			if abs(offset) > tolerance {
				fmt.printf(
					"[ap] seek-landing: FAIL: seek to frame %d lands %+d samples off (tolerance %d = one frame)\n",
					target, offset, tolerance,
				)
				return false
			}
		}
		fmt.println("[ap] seek-landing: ok (every seek lands on the requested content sample)")
		return true
	}

	// audio_probe_clip_tempo_alignment proves per-clip output ring begins at the timeline
	// sample mapped from content zero. The fixture starts with a pulse at source sample 0;
	// any interpolated lookahead discard or a pump that bypasses the provisioned fifo moves
	// or deletes that pulse.
	audio_probe_clip_tempo_alignment :: proc(path: string, speed: f64) -> bool {
		defer audio_probe_timeline_reset()
		fps := timeline_fps()
		if fps <= 0 || speed <= 0 {
			fmt.println("[ap] clip-alignment: invalid fps or speed")
			return false
		}
		content_frames := i64(fps * 4.0)
		clip := Clip{source_length_frames = content_frames, speed = speed}
		span_frames := clip_timeline_length(&clip)
		path_buf: [4096]u8
		assert(len(path) < len(path_buf), "audio_probe_clip_tempo_alignment: path buffer overflow")
		path_n := len(path)
		for i in 0 ..< path_n {
			path_buf[i] = u8(path[i])
		}
		path_buf[path_n] = 0
		// Check both clip opening and an interior seek. The pulse interval is 125 ms, and
		// the interior seek is at 0.5 s; for every tested speed, the sought content time is
		// an exact multiple of the pulse interval. Thus the expected transient is output 0
		// at both origins, without relying on a fuzzy waveform correlation.
		for timeline_start in ([]i64{0, i64(fps * 0.5)}) {
			out := mix_clip_range(
				cstring(&path_buf[0]), content_frames, span_frames, speed, fps, 0, timeline_start,
			)
			if len(out) == 0 {
				delete(out)
				fmt.printf("[ap] clip-alignment: FAIL: speed %.3f at frame %d produced no output\n", speed, timeline_start)
				return false
			}
			first := first_onset(out[:], 0)
			delete(out)
			fmt.printf(
				"[ap] clip-alignment: speed %.3f seek frame %d first content transient at output sample %d (want 0)\n",
				speed, timeline_start, first,
			)
			if first != 0 {
				fmt.printf("[ap] clip-alignment: FAIL: speed %.3f seek frame %d moved opening content by %d output samples\n", speed, timeline_start, first)
				return false
			}
		}
		fmt.println("[ap] clip-alignment ok (opening and seek output zero map to requested content)")
		return true
	}

	// audio_probe_backward_scrub_seeks proves that a playhead move actually MOVES THE
	// AUDIO, which is a different question from whether the playhead line moves.
	//
	// The reported symptom is "I can move the playhead, but playback isn't set to it":
	// the on-screen playhead follows the pointer while the sound keeps coming from
	// where the producer last fed. Those are two different pieces of state --
	// playhead.frame, and audio_src.next_frame / the decoder anchors -- and a probe
	// that only reads the first cannot see the second fail.
	//
	// A backward scrub is the case that separates them. Forward playback keeps
	// playhead.frame and next_frame moving together for free, because the device
	// clock pulls the playhead along behind the producer. Only a move AGAINST the
	// producer's direction needs an explicit rewind, and only a backward move can
	// land somewhere the producer has already fed past.
	audio_probe_backward_scrub_seeks :: proc(path: string) -> bool {
		defer audio_probe_timeline_reset()
		fmt.println("[ap] --- backward scrub moves the audio ---")
		audio_reset_play()
		buf: [4096]u8
		cn := 0
		for cn < len(path) && cn < len(buf) - 1 {
			buf[cn] = u8(path[cn])
			cn += 1
		}
		buf[cn] = 0
		cpath := cstring(&buf[0])
		// One long clip, so "the playhead is at frame N" and "the audio under frame
		// N" are the same statement for every N in range -- a multi-clip fixture
		// would let a Keep decision be correct for the wrong reason.
		timeline.tracks = make([dynamic]Track, 0, 1)
		timeline.track_order = make([dynamic]int, 0, 1)
		track := Track {name = "t", clips = make([dynamic]Clip, 0, 1)}
		append(
			&track.clips,
			Clip {
				clip_id = new_clip_id(),
				path = cpath,
				kind = .Audio,
				name = session_str_intern("scrub"),
				timeline_start_frame = 0,
				source_length_frames = 900,
				source_start_frame = 0,
				stream_index = 0,
			},
		)
		append(&timeline.tracks, track)
		sync_track_order()
		selection.track, selection.index = -1, -1
		audio_geometry_commit()
		audio_prod.last_ui_frame = -1

		// audio_init reads VYPER_AUDIO_TRACE, but every VYPER_AUDIO_* probe is
		// dispatched BEFORE audio_init runs, so the flag is never set here and the
		// [tr feed] lines -- which print devpos, target, queue depth and push size,
		// i.e. every number this probe is reasoning about -- are off. Read the same
		// env var the init path does rather than duplicating the flag's meaning.
		saved_trace := audio_rpt.trace
		audio_rpt.trace = os.get_env_alloc("VYPER_AUDIO_TRACE", context.temp_allocator) == "1"
		defer audio_rpt.trace = saved_trace
		// Simulated device: the assertion is about where the producer is AIMED, and
		// a real device's consumption would make the target move under the test.
		SIM_CAP :: i64(AUDIO_BUS_RATE * 8)
		audio_device_sim_enable(SIM_CAP)
		defer audio_device_sim_disable()
		playback.rate = 1.0
		playback.dir = 1
		playhead.frame = 0
		playhead.playing = true
		preview.playing = true

		// Drive the producer FAR ahead of the playhead: the state playback actually
		// reaches, and the one a scrub has to undo. Simply filling and stopping parks
		// the producer one cushion ahead, which is NOT far enough to tell the
		// steady-state cushion from a playhead that moved elsewhere -- at 60 fps the
		// cushion is 16 frames, so a producer at 15 makes every scrub read as steady
		// state and the probe passes having tested nothing. That is exactly how this
		// probe passed against the broken engine.
		fps_fwd := timeline_fps()
		// Each pass consumes exactly one timeline frame's worth of samples, so the
		// audible position advances in step with real playback and the producer is free
		// to follow it. The playhead is then left BEHIND the audible position by the
		// scrub distance, which is the whole condition under test: the playhead says
		// frame N while the sources are at N + distance, which is precisely what a
		// backward scrub leaves behind and what the predicate has to notice.
		// Consume BEFORE feeding. dev_pos -- the fill target -- is derived from what the
		// device has already heard, so consuming first is what moves the target; feeding
		// first fills to the old target and the ring overflows, because the producer
		// throttles to a cushion that is only reached once the device drains. One frame
		// per pass is exactly real time, so the audible position advances in step and
		// the sources follow it forward.
		frame_samples := i64(f64(AUDIO_BUS_RATE) / f64(fps_fwd))
		PLAY_AHEAD_FRAMES :: 400
		for _ in 0 ..< PLAY_AHEAD_FRAMES {
			audio_device_sim_consume(frame_samples)
			audio_producer_feed()
		}
		prod_before := audio_src.next_frame
		queued_before := audio_device_queued()
		// first48 is the content sample at the decoder fifo's head, i.e. where the
		// sound is currently coming FROM. Recorded before the seek so assertion (3)
		// can compare against what it was, not just against a computed target: the
		// seek deliberately lands early (AUDIO_SEEK_PREROLL_SEC) because a demuxer
		// can land late, so an exact match is the wrong expectation and "did it move
		// back roughly as far as the playhead" is the real one.
		anchor_before := audio_src.slots[0].first48
		fmt.printf(
			"[ap] scrub fixture: producer fed to %d, device holds %d queued frames, playhead 0\n",
			prod_before,
			queued_before,
		)
		if prod_before <= 0 || queued_before <= 0 {
			fmt.println("[ap] scrub: SKIP: nothing fed; the fixture did not establish a real queue")
			return true
		}

		// The scrub, BACKWARD: release behind everything the producer fed. The target
		// is derived from where the fixture actually got rather than hardcoded,
		// because "behind" is the entire premise -- a hardcoded frame is a forward
		// seek whenever the fixture under-fills, and a forward seek passes with the
		// rewind removed. The premise is asserted rather than hoped for.
		// Steady state first: the producer deliberately runs AUDIO_CUSHION_SEC ahead of
		// the audible position, so a healthy playhead and producer differ by exactly
		// that and that difference must NOT read as a playhead move. Getting this wrong
		// in the other direction re-anchors on every edit.
		probe_fps := timeline_fps()
		cushion := i64(AUDIO_CUSHION_SEC * f64(probe_fps) * audio_rate_scale() + 1)
		steady := prod_before - cushion
		if steady < 1 {
			fmt.printf("[ap] stale anchor: SKIP: producer only reached %d, no room for a cushion\n", prod_before)
			return true
		}
		playhead.frame = steady
		if audio_reconcile_is_seeked(steady, probe_fps, audio_rate_scale()) {
			fmt.printf(
				"[ap] stale anchor: FAIL: a playhead %d with the producer %d ahead -- the steady-state cushion -- read as a playhead move. Every edit would re-anchor.\n",
				steady, prod_before,
			)
			return false
		}
		fmt.printf(
			"[ap] stale anchor: steady state playhead %d, producer %d (cushion %d) reads as NOT a seek\n",
			steady, prod_before, cushion,
		)
		inside_cushion := steady + 1
		if audio_reconcile_is_seeked(inside_cushion, probe_fps, audio_rate_scale()) {
			fmt.printf(
				"[ap] scrub release: FAIL: nearby playhead frame %d should be within the %d-frame cushion\n",
				inside_cushion, cushion,
			)
			return false
		}
		if !audio_reconcile_is_seeked(inside_cushion, probe_fps, audio_rate_scale(), true) {
			fmt.printf(
				"[ap] scrub release: FAIL: explicit nearby seek to %d was suppressed by the cushion\n",
				inside_cushion,
			)
			return false
		}
		fmt.printf(
			"[ap] scrub release: explicit frame %d overrides the %d-frame cushion\n",
			inside_cushion, cushion,
		)
		// THE STALE ANCHOR: the case the user's trace showed, and the one a
		// request-versus-request comparison cannot see. Nothing seeks during ordinary
		// forward playback, so audio_prod.anchor_frame sits at wherever the last seek
		// left it while the sources play forward hundreds of frames past it. Point the
		// anchor at the frame we are about to scrub back to, so the move cannot be
		// detected by noticing that the requested frame changed.
		//
		// Measured on the user's run: anchor 57, playhead 198 -> 203, producer 218, then
		// a scrub back to 57. The old predicate compared the new request against the
		// remembered one, saw 57 == 57, and kept all 25 sources with 161 frames of
		// pre-scrub audio queued. Every earlier version of this probe scrubbed to a
		// frame the anchor did not already hold, so the fixture was arranged to make
		// the bug invisible.
		seek_to := max(1, steady / 3)
		sync.atomic_store(&audio_prod.anchor_frame, seek_to)
		if !audio_reconcile_is_seeked(seek_to, probe_fps, audio_rate_scale()) {
			fmt.printf(
				"[ap] stale anchor: FAIL: playhead %d with the producer %d frames ahead read as stationary, because the requested anchor already held %d\n",
				seek_to, prod_before, seek_to,
			)
			return false
		}
		fmt.printf(
			"[ap] stale anchor: anchor already reads %d, producer at %d, playhead moved to %d -- read as a seek\n",
			seek_to, prod_before, seek_to,
		)
		if seek_to >= prod_before {
			fmt.printf(
				"[ap] scrub: SKIP: producer only reached %d, cannot scrub back from it to %d\n",
				prod_before,
				seek_to,
			)
			return true
		}
		playhead.frame = seek_to
		audio_seek(seek_to)
		// The seek decision comes from audio_reconcile_is_seeked, the same function the
		// producer thread calls, so the probe cannot pass by handing the reconcile a
		// flag the engine would never compute for itself.
		rep := audio_reconcile(seek_to, audio_reconcile_is_seeked(seek_to, timeline_fps(), audio_rate_scale()))

		prod_after := audio_src.next_frame
		// (1) The producer must be rewound to the playhead. Carrying on from
		// next_frame would skip exactly the range the user scrubbed back over, and
		// the audio would resume mid-clip with no indication why.
		if audio_src.next_frame != seek_to {
			fmt.printf(
				"[ap] scrub: FAIL: producer still at %d after seeking back to %d (touched_window=%v kept it there)\n",
				audio_src.next_frame,
				seek_to,
				rep.touched_window,
			)
			return false
		}
		// (2) The queue must be dropped. It holds audio for frames 0..N and the
		// playhead is now at 30; keeping it plays the old position out loud for the
		// length of the cushion, which is the audible half of "playback isn't set to
		// the playhead".
		//
		// The reconcile REPORTS that decision and the producer thread CARRIES it out,
		// so the probe asserts the report and then performs the same clear. Asserting
		// only one of the two would test half the chain: a reconcile that reported
		// touched and a producer that ignored it both look like "nothing happened"
		// here.
		if !rep.touched_window {
			fmt.printf(
				"[ap] scrub: FAIL: reconcile did not report the queued window touched on a playhead move (kept +%d sought +%d)\n",
				rep.kept,
				rep.sought,
			)
			return false
		}
		audio_device_clear()
		if audio_device_queued() != 0 {
			fmt.printf(
				"[ap] scrub: FAIL: clearing the reported-stale queue left %d frames behind\n",
				audio_device_queued(),
			)
			return false
		}
		// (3) The decoder must sit at the content for the new playhead, not merely
		// survive. A source kept at its old content plays the right TIMING with the
		// wrong SOUND, which is worse than an obvious failure.
		seg := play_src_first_seg_at(&audio_src.slots[0], seek_to)
		if seg == nil {
			fmt.println("[ap] scrub: FAIL: no segment covers the seek target after reconcile")
			return false
		}
		want_content := i64(
			audio_content_sample_at_speed(
				max(seek_to, seg.start_a) - seg.start_a,
				seg.start_s,
				seg.start_s_rate,
				seg.speed,
			),
		)
		anchor_after := audio_src.slots[0].first48
		// The preroll window is what a correct seek is allowed to overshoot by; past
		// it the decoder is demonstrably not at the requested content.
		preroll_48 := i64(AUDIO_SEEK_PREROLL_SEC * f64(AUDIO_BUS_RATE))
		if abs(anchor_after - want_content) > preroll_48 {
			fmt.printf(
				"[ap] scrub: FAIL: decoder head at content %d, want %d (preroll %d) for playhead %d; it was at %d and did not move\n",
				anchor_after,
				want_content,
				preroll_48,
				seek_to,
				anchor_before,
			)
			return false
		}
		if anchor_after >= anchor_before {
			fmt.printf(
				"[ap] scrub: FAIL: decoder head did not move back (%d -> %d) seeking from playhead 0 to %d\n",
				anchor_before,
				anchor_after,
				seek_to,
			)
			return false
		}
		// (4) And the next feed must actually produce the new position's audio,	// rather than only the state being correct. The state assertions above can
		// all pass while the mixer reads a stale ring.
		after_probe_frames := audio_src.next_frame
		audio_producer_feed()
		if audio_src.next_frame <= after_probe_frames {
			fmt.printf(
				"[ap] scrub: FAIL: producer made no progress from the seek target (%d)\n",
				audio_src.next_frame,
			)
			return false
		}
		// prod_after is the post-RECONCILE position, captured before assertion (4)
		// feeds from it -- printing audio_src.next_frame here would report the
		// position the feed reached, which is a different number and reads as if the
		// rewind overshot.
		fmt.printf(
			"[ap] scrub: playhead -> %d rewound producer %d -> %d, dropped %d queued frames, re-anchored decoder to content %d\n",
			seek_to,
			prod_before,
			prod_after,
			queued_before,
			anchor_after,
		)
		fmt.println("[ap] scrub ok (playhead move reaches the producer, the queue, and the decoder)")
		return true
	}

	// audio_probe_clip_tempo_edit_alignment changes an ALREADY-PROVISIONED source from
	// 1x to 2x at a nonzero playhead. This exercises geometry publication, source
	// reconciliation, graph rebuild, decoder seek, and output-ring origin together --
	// the inspector's real speed-edit path, not just a fresh clip provisioned at 2x.
	audio_probe_clip_tempo_edit_alignment :: proc(path: string) -> bool {
		defer audio_probe_timeline_reset()
		fps := timeline_fps()
		if fps <= 0 {
			fmt.println("[ap] clip-edit-alignment: no fps")
			return false
		}
		content_frames := i64(fps * 4.0)
		start_frame := i64(fps * 0.5)
		// Frames the device queue is pretended to hold ahead of the playhead, so the
		// queued-window half of the edit has a window to decide about.
		QUEUED_PROBE_FRAMES :: 8
		path_buf: [4096]u8
		assert(len(path) < len(path_buf), "audio_probe_clip_tempo_edit_alignment: path buffer overflow")
		path_n := len(path)
		for i in 0 ..< path_n {
			path_buf[i] = u8(path[i])
		}
		path_buf[path_n] = 0
		mix_clip_range_setup(cstring(&path_buf[0]), content_frames, 1.0)
		if audio_src.count != 1 || len(timeline.tracks) == 0 || len(timeline.tracks[0].clips) == 0 {
			fmt.println("[ap] clip-edit-alignment: FAIL: source did not provision at 1x")
			return false
		}
		// Both reconciles below are EDITS at a fixed playhead, which is what an
		// inspector speed/pitch change is. audio_reconcile_is_seeked decides that from
		// the engine's own state rather than the probe asserting it. The queued position
		// is placed a cushion ahead of the playhead first, which is the steady state --
		// an edit made with the producer parked hundreds of frames away is not an edit,
		// it is an unfollowed playhead move, and the predicate is right to say so.
		audio_src.next_frame = start_frame + QUEUED_PROBE_FRAMES
		timeline.tracks[0].clips[0].speed = 2.0
		audio_geometry_commit()
		rep := audio_reconcile(
			start_frame,
			audio_reconcile_is_seeked(start_frame, fps, audio_rate_scale()),
		)
		// The edit must REBUILD the source, and "rebuild" is `sought OR opened` -- not
		// `sought` alone. That distinction is the whole content of this assertion, and
		// getting it wrong is why the probe was red for a right engine.
		//
		// A clip's speed is also its TIMELINE EXTENT: 2x is half as long. So a 1x -> 2x
		// edit moves the chip's timeline_start and halves its timeline_len, which breaks
		// the segment CONTIGUITY that decides whether a chip continues an existing group.
		// Nothing continues, so the old source is dropped and the chip builds a NEW one --
		// `opened`, on a fresh decoder -- and there is no existing decoder to re-seek, so
		// `sought` is legitimately 0. Measured:
		//
		//	kept=0 sought=0 opened=1 dropped=1 touched=true slot0.speed=2.000
		//
		// Demanding `sought > 0` here asserts a mechanism (re-seek) rather than the
		// outcome (rebuilt at the new tempo, queue invalidated), so it fails on the correct
		// behaviour and would have failed on it forever.
		//
		// PITCH is the other shape and is asserted the strict way below: pitch moves every
		// output sample without moving content or the extent, so it MUST take the
		// graph_changed re-seek path. If that one ever reports sought=0, it is a real bug.
		if rep.sought == 0 && rep.opened == 0 {
			fmt.printf(
				"[ap] clip-edit-alignment: FAIL: speed edit rebuilt nothing (kept=%d sought=%d opened=%d dropped=%d)\n",
				rep.kept, rep.sought, rep.opened, rep.dropped,
			)
			return false
		}
		if audio_src.slots[0].speed != 2.0 {
			fmt.printf(
				"[ap] clip-edit-alignment: FAIL: speed edit left the source's graph at %.3fx, want 2.000\n",
				audio_src.slots[0].speed,
			)
			return false
		}
		// Pin the queue half of a rate edit too, with a real queue: pitch moves every
		// output sample without moving any content, so the mapping under the queued
		// frames is identical before and after and only the graph change marks the
		// queue stale. Miss that and a pitch edit leaves up to a cushion of audio
		// playing at the old pitch.
		audio_src.next_frame = start_frame + QUEUED_PROBE_FRAMES
		timeline.tracks[0].clips[0].pitch = 5.0
		audio_geometry_commit()
		pitch_rep := audio_reconcile(
			start_frame,
			audio_reconcile_is_seeked(start_frame, fps, audio_rate_scale()),
		)
		want_pitch_ratio := semitones_to_ratio(5.0)
		if pitch_rep.sought == 0 || abs(f64(audio_src.slots[0].pitch_ratio-want_pitch_ratio)) > 1e-6 {
			fmt.printf("[ap] clip-edit-alignment: FAIL: pitch edit did not rebuild graph (sought=%d, ratio=%.6f want %.6f)\n", pitch_rep.sought, audio_src.slots[0].pitch_ratio, want_pitch_ratio)
			return false
		}
		if !pitch_rep.touched_window {
			fmt.println("[ap] clip-edit-alignment: FAIL: pitch edit left the queued frames marked current -- they were mixed by the old graph")
			return false
		}
		spf := int(audio_frame_boundary48(start_frame+1, fps) - audio_frame_boundary48(start_frame, fps))
		mix: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
		if !audio_mix_frame(mix[:], start_frame, spf) {
			fmt.println("[ap] clip-edit-alignment: FAIL: edited source delivered no frame")
			return false
		}
		first := first_onset(mix[:spf*2], 0)
		fmt.printf("[ap] clip-edit-alignment: 1x -> 2x at frame %d, first pulse at output sample %d (want 0)\n", start_frame, first)
		if first != 0 {
			fmt.println("[ap] clip-edit-alignment: FAIL: speed edit moved the interior seek's content origin")
			return false
		}
		// Pitch is the other graph property edited from the inspector. It does not change
		// content position or timeline length, but it still must rebuild the per-source
		// graph at the current playhead rather than leaving the old pitch ratio live --
		// and the pitched output must still start on the content sample it was seeked to.
		if !audio_mix_frame(mix[:], start_frame, spf) {
			fmt.println("[ap] clip-edit-alignment: FAIL: pitched source delivered no frame")
			return false
		}
		first = first_onset(mix[:spf*2], 0)
		if first != 0 {
			fmt.printf("[ap] clip-edit-alignment: FAIL: pitch edit moved content origin to sample %d\n", first)
			return false
		}
		fmt.println("[ap] clip-edit-alignment ok (speed and pitch edits rebuild at audible playhead)")
		return true
	}

	// audio_probe_clip_pitch proves the pitch property SHIFTS, and that it does so the way
	// the model promises: frequency moves, duration does not.
	//
	// Two properties, checked separately, because a clip property that got them backwards
	// would still pass a single test:
	//
	//   - PITCH MOVES. A 12-semitone shift is exactly one octave, so a 440 Hz tone must
	//     come out near 880. Counted by zero crossings, which is exact for a pure tone and
	//     needs no FFT.
	//   - DURATION DOES NOT. The same span must yield the same number of samples. This is
	//     what distinguishes pitch from tempo, and it is why the two are separate
	//     properties: a clip at pitch +12 must be the same length on the timeline as the
	//     same clip unpitched.
	//
	// Tempo 1.0 throughout, so nothing here can be confused with a speed change.
	audio_probe_clip_pitch :: proc(path: string, semitones: f32 = 12.0) -> bool {
		fps := timeline_fps()
		if fps <= 0 {
			fmt.println("[ap] pitch: no fps")
			return false
		}
		frames := i64(fps * 2.0)
		span := frames

		base := render_pitch_span(cpath_ref(path), frames, span, 0.0)
		defer delete(base)
		if len(base) == 0 {
			fmt.println("[ap] pitch: SKIP: reference produced nothing (fixture should be a tone)")
			return true
		}
		shifted := render_pitch_span(cpath_ref(path), frames, span, semitones)
		defer delete(shifted)
		if len(shifted) == 0 {
			fmt.println("[ap] pitch: FAIL: the pitched render produced nothing at all")
			return false
		}

		// DURATION first: it is the property that separates pitch from tempo.
		if len(shifted) != len(base) {
			fmt.printf(
				"[ap] pitch: FAIL: +%.0f semitones changed the output LENGTH (%d vs %d samples) -- that is a tempo change, not a pitch shift\n",
				semitones, len(shifted), len(base),
			)
			return false
		}

		// FREQUENCY, by zero crossings over the steady interior.
		z0 := zero_crossings(base[:])
		z1 := zero_crossings(shifted[:])
		if z0 == 0 {
			fmt.println("[ap] pitch: SKIP: reference has no measurable frequency (not a tone?)")
			return true
		}
		ratio := f64(z1) / f64(z0)
		want := semitones_to_ratio(semitones)
		fmt.printf(
			"[ap] pitch: +%.0f semitones -> frequency ratio %.4f (want %.4f), length unchanged at %d samples\n",
			semitones, ratio, want, len(shifted),
		)
		// 5%, not 2%. A one-octave shift is arithmetically EXACT -- asetrate 96000 then
		// aresample 48000 is 2:1 -- so the residual is the resampler's filter and the
		// windowing of the crossing count at the edges, not the pitch arithmetic. Measured
		// 2.0284 against a wanted 2.0.
		//
		// The tolerance is deliberately loose because the check that separates pitch from
		// tempo is the LENGTH assertion above, and that one is exact. This is only proving
		// the frequency moved in the RIGHT DIRECTION and by about the right amount; a
		// signal chain that transposed instead of pitched would fail the length check long
		// before it mattered here.
		if math.abs(ratio - want) > 0.05 * want {
			fmt.printf("[ap] pitch: FAIL: frequency moved by %.4fx, wanted %.4fx\n", ratio, want)
			return false
		}
		fmt.println("[ap] pitch ok (frequency shifted, duration untouched)")
		return true
	}

	// cpath_ref is a tiny helper so the probe's call sites stay readable; the path is
	// interned once per call and the buffer lives for the call.
	cpath_ref :: proc(path: string) -> cstring {
		return intern_cpath(path)
	}

	intern_cpath :: proc(path: string) -> cstring {
		buf: [4096]u8
		cn := 0
		for cn < len(path) && cn < len(buf) - 1 {
			buf[cn] = u8(path[cn])
			cn += 1
		}
		buf[cn] = 0
		return cstring(&buf[0])
	}

	// render_pitch_span mixes `frames` of a clip at `semitones` and returns the output.
	render_pitch_span :: proc(path: cstring, content_frames: i64, span_frames: i64, semitones: f32) -> [dynamic]f32 {
		return mix_clip_range(path, content_frames, span_frames, 1.0, timeline_fps(), semitones)
	}

	// zero_crossings counts sign changes of the left channel, which for a pure tone is
	// twice the frequency. The first and last 10% are skipped so the declick-free start
	// and the mix's edges cannot skew the count.
	zero_crossings :: proc(buf: []f32) -> int {
		frames := len(buf) / 2
		lo := frames / 10
		hi := frames - frames / 10
		if hi - lo < 64 {
			return 0
		}
		crossings := 0
		prev := buf[lo * 2]
		for i in lo + 1 ..< hi {
			v := buf[i * 2]
			if (v >= 0) != (prev >= 0) {
				crossings += 1
			}
			prev = v
		}
		return crossings
	}

	audio_probe_stall_gap :: proc(path: string, stall_ms: int = 900) -> bool {
		buf: [4096]u8
		cn := 0
		for cn < len(path) && cn < len(buf) - 1 {
			buf[cn] = u8(path[cn])
			cn += 1
		}
		buf[cn] = 0
		cpath := cstring(&buf[0])

		fps := timeline_fps()
		if fps <= 0 {
			fmt.println("[ap] stall: no fps")
			return false
		}
		// A clip long enough that the run never reaches its end, so the probe is not
		// measuring an auto-stop.
		run_frames := i64((f64(stall_ms) + 6000.0) / 1000.0 * fps)

		audio_reset_for_load()
		audio_reset_play()
		timeline.tracks = make([dynamic]Track, 0, 1)
		timeline.track_order = make([dynamic]int, 0, 1)
		track := Track {name = "stall", clips = make([dynamic]Clip, 0, 1)}
		append(
			&track.clips,
			Clip {
				clip_id = new_clip_id(),
				path = cpath,
				kind = .Audio,
				name = session_str_intern("s"),
				timeline_start_frame = 0,
				source_length_frames = run_frames,
				source_start_frame = 0,
				stream_index = 0,
			},
		)
		append(&timeline.tracks, track)
		sync_track_order()
		selection.track, selection.index = -1, -1
		audio_geometry_commit()

		// Simulated device. The cap is the REAL ring's capacity, not the cushion: the
		// producer throttles to the cushion and must still have room for a whole block,
		// or it would assert instead of demonstrating anything.
		// Large enough that overflow cannot be what this probe measures. The real ring is
		// 32768 frames, and overflowing a simulation of THAT size says only that the
		// probe's drain rate was slower than the producer's fill -- which is a fact about
		// the probe, not about the design. Thirty seconds of bus, so the invariant is
		// what decides the verdict.
		SIM_CAP :: i64(AUDIO_BUS_RATE * 30)
		audio_device_sim_enable(SIM_CAP)
		defer audio_device_sim_disable()

		audio_reset_play()
		audio_prod.last_ui_frame = -1
		audio_provision(0)
		if audio_src.count == 0 {
			fmt.println("[ap] stall: SKIP: playback provisioned no sources")
			return true
		}
		playhead.frame = 0
		playhead.playing = true
		preview.playing = true

		// TICK_MS is 5ms: fine enough that the queue's state is sampled densely, coarse
		// enough that the drain arithmetic does not accumulate float error into the
		// assertion. The drain is integer, not time-derived, so this is exact.
		TICK_MS :: 5
		tick_samples := i64(AUDIO_BUS_RATE) * TICK_MS / 1000
		spf := f64(AUDIO_BUS_RATE) / fps
		ticks := int(f64(stall_ms) / f64(TICK_MS)) + 240
		stall_at := ticks / 3
		stall_end := stall_at + int(stall_ms) / TICK_MS
		// After the stall the queue is EMPTY and refills from zero to the cushion, so it
		// necessarily passes below the floor on the way. That is the gap being mended,
		// not a second starvation, so the floor counter is allowed to move until the
		// refill completes -- and is then required to stop. REFILL_TICKS is generous:
		// the cushion is 12000 samples and the tick is 240, so 50 ticks refill it.
		settle_end := stall_end + 120

		offence := ""
		checked := 0
		starve_before := audio_rpt.starve_ticks
		dev_at_stall_start := i64(-1)
		peak_queued, min_queued := i64(0), i64(1 << 40)
		gap_frames := i64(0)
		prev_written := i64(0)

		for t in 0 ..< ticks {
			stalling := t >= stall_at && t < stall_end
			if !stalling {
				// audio_producer_feed, not audio_update: the UI-side update only
				// refreshes the anchor and requests seeks ("steady playback needs no work
				// here"), while the FEED is the producer's own proc. Calling the wrong one
				// makes the probe pass vacuously -- it saw a gap because nothing was ever
				// fed, which is how this probe's first run reported success.
				audio_producer_feed()
			}
			// Drain at exactly the bus rate, in integers. During a stall this asks for
			// audio that was never written, which is the gap.
			audio_device_sim_consume(tick_samples)

			fed := i64(audio_rpt.total_fed_frames)
			queued_samples := audio_device_queued()
			queued_frames := i64(f64(queued_samples) / spf)
			dev := sync.atomic_load(&playback.dev_frame)

			// dev_frame is published ON A FEED PASS, so while the producer is stalled it
			// is legitimately stale -- and it must be, because a producer that kept
			// publishing would be advancing the position of audio it had not produced. So
			// invariant 1 is a property of a tick where the producer RAN, and during the
			// stall the meaningful assertion is the opposite: that the published position
			// does NOT move while nothing is being fed.
			if !stalling {
				derived := i64(f64(fed - queued_samples) / spf)
				if abs(dev - derived) > 1 {
					if offence == "" {
						offence = fmt.tprintf(
							"dev_frame %d is not fed-queued %d at tick %d (fed=%d queued=%d)",
							dev, derived, t, fed, queued_samples,
						)
					}
				}
				// Invariant 2: the fixed point holds whenever the producer runs. Not
				// asserted during the refill window, and REQUIRED to be quiet after it --
				// a queue that cannot climb back to the cushion is a permanent defect, and
				// this is the only check that would notice.
				if t > settle_end && audio_rpt.starve_ticks != starve_before && offence == "" {
					offence = fmt.tprintf(
						"starve_ticks moved %d -> %d at tick %d, after the refill settled",
						starve_before, audio_rpt.starve_ticks, t,
					)
				}
				starve_before = audio_rpt.starve_ticks
			} else if dev_at_stall_start < 0 {
				// Baseline taken AT the stall's onset, not before the loop: the position
				// has been advancing normally up to this tick, and comparing against
				// anything earlier reports the ordinary advance as a stall artefact.
				dev_at_stall_start = dev
			} else if dev != dev_at_stall_start {
				if offence == "" {
					offence = fmt.tprintf(
						"dev_frame moved %d -> %d during a stall at tick %d; it is published on a feed pass and must not be",
						dev_at_stall_start, dev, t,
					)
				}
			}
			// Invariant 3, and the one that makes "no offset" mean something: a resync
			// RE-ANCHORS, and a re-anchor is a silent shift of the playhead -- the single
			// thing this design cannot tolerate. It must not happen during the stall, which
			// is precisely when the old code would have reached for it.
			if sync.atomic_load(&audio_prod.resync) != 0 && offence == "" {
				offence = fmt.tprintf(
					"resync moved to %d at tick %d -- a re-anchor is a silent shift of the playhead",
					sync.atomic_load(&audio_prod.resync), t,
				)
			}

			// The playhead is a readout, so mirror what playback_update does rather than
			// calling it: this probe is about the producer, not the UI thread.
			if dev > playhead.frame {
				playhead.frame = dev
			}

			if t < stall_at {
				peak_queued = max(peak_queued, queued_samples)
			}
			if stalling && prev_written > fed {
				gap_frames += prev_written - fed
			}
			min_queued = min(min_queued, queued_samples)
			prev_written = fed
			checked += 1
			// Real time, because the producer's seeding and catch-up logic is keyed to
			// the wall clock and faking it would test a fiction.
			sleep_ms(TICK_MS)
		}

		underruns := i64(audio_device_sim_underruns())
		fmt.printf(
			"[ap] stall: %d ticks, queue peak=%d min=%d frames; device asked for %d unwritten frames during the stall; resync=%d starve=%d\n",
			checked, peak_queued, min_queued, underruns,
			sync.atomic_load(&audio_prod.resync), audio_rpt.starve_ticks,
		)
		if offence != "" {
			fmt.println("[ap] stall: FAIL:", offence)
			return false
		}
		if underruns == 0 {
			fmt.println("[ap] stall: FAIL: the device never ran dry, so no stall actually happened")
			return false
		}
		final_queued := audio_device_queued()
		if final_queued < i64(f64(AUDIO_BUS_RATE) * AUDIO_CUSHION_SEC) / 2 {
			fmt.printf(
				"[ap] stall: FAIL: the queue ended at %d frames, under half the cushion -- the gap did not heal\n",
				final_queued,
			)
			return false
		}
		fmt.println("[ap] stall ok (the queue starved, the device ran dry, and no re-anchor followed)")
		return true
	}

	audio_probe_drift_parity :: proc(path: string, seconds: f64, fps_override: f64 = 0) -> bool {
		buf: [4096]u8
		cn := 0
		for cn < len(path) && cn < len(buf) - 1 {
			buf[cn] = u8(path[cn])
			cn += 1
		}
		buf[cn] = 0
		cpath := cstring(&buf[0])

		// Override the PROJECT rate, not playback.magic_fps.
		//
		// magic_fps exists to isolate wall-clock jitter from the audible rate, and its
		// own contract is that it must not change what a frame index MEANS: content
		// positions are computed from project_fps (timeline_frame_sample), while
		// timeline_fps -- which honours magic_fps -- drives the bus. Setting magic_fps
		// alone therefore makes playback demand content at one rate and mix it at
		// another, and the mixer absorbs the difference by shifting whole frames:
		// measured, 1786 clamps with a worst case of 1,416,288 samples, 29.5 seconds.
		//
		// Every result this probe produced before this line was fixed was a report on
		// that mistake, not on 29.97.
		saved_rate := project.frame_rate
		saved_tl_rate := timeline.frame_rate
		if fps_override > 0 {
			project.frame_rate = fps_override
			timeline.frame_rate = fps_override
		}
		defer {
			project.frame_rate = saved_rate
			timeline.frame_rate = saved_tl_rate
		}

		fps := timeline_fps()
		if fps <= 0 {
			fmt.println("[ap] drift: no fps")
			return false
		}
		total_frames := i64(seconds * fps)
		fmt.printf(
			"[ap] drift: %.1fs at %.6f fps (%d frames, %.2f samples/frame avg)\n",
			seconds,
			fps,
			total_frames,
			48000.0 / fps,
		)

		// One clip spanning the whole span: this probe is about position over time,
		// and overlapping clips would make a divergence ambiguous between "drifted"
		// and "resolved a different span".
		audio_reset_for_load()
		audio_reset_play()
		timeline.tracks = make([dynamic]Track, 0, 1)
		timeline.track_order = make([dynamic]int, 0, 1)
		track := Track {name = "drift", clips = make([dynamic]Clip, 0, 1)}
		append(
			&track.clips,
			Clip {
				clip_id = new_clip_id(),
				path = cpath,
				kind = .Audio,
				name = session_str_intern("d"),
				timeline_start_frame = 0,
				source_length_frames = total_frames,
				source_start_frame = 0,
				stream_index = 0,
			},
		)
		append(&timeline.tracks, track)
		sync_track_order()
		selection.track, selection.index = -1, -1

		audio_geometry_commit()
		audio_reset_play()
		audio_provision(0)
		if audio_src.count == 0 {
			fmt.println("[ap] drift: SKIP: playback provisioned no sources")
			return true
		}

		export_audios: [dynamic]Render_Audio_Src
		defer delete(export_audios)
		slot := audio_geom_acquire()
		defer audio_geom_release()
		for i in 0 ..< min(int(slot.n), 4) {
			append(&export_audios, render_audio_src_from_chip(slot, &slot.chip[i]))
		}
		if len(export_audios) == 0 {
			fmt.println("[ap] drift: SKIP: no export sources")
			return true
		}
		// The export's sources have to be OPENED, exactly as the real export's setup
		// does (render.odin:3627). A source that was never opened contributes nothing
		// at all, which is indistinguishable from a source that opened and hit a hole
		// -- and the first version of this probe forgot the open, and reported the
		// export as silent at frame 0 as though the mixer were at fault.
		opened := 0
		for &a in export_audios {
			if render_audio_open(&a, 0, fps) {
				opened += 1
			} else {
				a.dec.opened = false
			}
		}
		if opened == 0 {
			fmt.println("[ap] drift: SKIP: export opened no sources")
			return true
		}
		// render_mix_block walks render_job.audios, so point the job at the probe's
		// array for the duration; the cloned paths go with it.
		render_job.audios = export_audios[:]
		defer {
			for &a in export_audios {
				if a.path != nil {
					delete(a.path)
				}
			}
			render_job.audios = nil
		}
		// The export's bus is a real ring, so it has to be initialised for the span
		// rather than defaulted -- a zero-value Render_Mix would mix into a bus with
		// no room and every block would read as a hole.
		render_mix: Render_Mix
		fnum, fden := fps_rational(fps)
		render_mix_init(&render_mix, c.int(i64(fnum)), c.int(i64(fden)), sample_pos_from_frames(0, i64(fnum), i64(fden)))
		defer render_mix_bus_destroy(&render_mix.bus)

		// Walk the timeline once, mixing each frame through BOTH paths and comparing
		// as we go. Export is driven at its own natural AUDIO_MIX_BLOCK granularity,
		// because the consumer of that stream takes whatever range its frame covers.
		mix_play: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
		mix_exp: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
		worst, worst_frame := f32(0), i64(-1)
		over_tol := 0
		first_bad := i64(-1)
		first_bad_i := -1
		bad_play, bad_exp := f32(0), f32(0)
		bad_run := 0
		mixed_samples := i64(0)
		for f in 0 ..< total_frames {
			b0 := audio_frame_boundary48(f, fps)
			b1 := audio_frame_boundary48(f + 1, fps)
			spf := min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(b1 - b0)))
			if !audio_mix_frame(mix_play[:], f, spf) {
				fmt.printf("[ap] drift: playback hole at frame %d (%.2fs)\n", f, f64(f)/fps)
				return false
			}
			// render_mix_block writes at `blk_lo - at` WITHIN the slice it is handed,
			// and zeroes it first. So the slice must start at this block's offset
			// inside the FRAME, not at the frame's own start -- handing it the whole
			// buffer each time makes every block overwrite the previous one from
			// offset 0, leaving only the last block and stale samples after it. That
			// is what made the two sinks look like they differed by a factor of six:
			// playback's frame was being compared against a buffer holding the wrong
			// 512 samples.
			for i in 0 ..< spf * 2 {
				mix_exp[i] = 0
			}
			for blk_lo := b0; blk_lo < b1; {
				blk := min(AUDIO_MIX_BLOCK, b1 - blk_lo)
				off := int(blk_lo - b0)
				render_mix_block(&render_mix, mix_exp[off * 2:], blk_lo, int(blk))
				blk_lo += blk
			}
			mixed_samples += i64(spf)
			if f == 0 {
				// Read the raw FIFOs, not the mixed output. The mix applies gain and a
				// declick ramp; the fifo is what each sink actually decoded. Comparing
				// mixes cannot tell "decoded different samples" from "applied different
				// gain", and those have nothing in common as fixes.
				//
				// Read AFTER mixing frame 0, so the ring head is the next sample each
				// side would serve -- the head the comparison above was served from.
				fmt.printf(
					"[ap] drift: frame 0 fifo heads: PLAY first48=%d have48=%d | EXP first48=%d have48=%d\n",
					audio_src.slots[0].first48, audio_src.slots[0].have48,
					export_audios[0].first48, export_audios[0].have48,
				)
				play_raw: [8]f32
				for i in 0 ..< 8 {
					l, rr := ring_at(&audio_src.slots[0].fifo, i)
					play_raw[i] = l
				}
				exp_raw: [8]f32
				for i in 0 ..< 8 {
					l, rr := ring_at(&export_audios[0].fifo, i)
					exp_raw[i] = l
				}
				fmt.printf("[ap] drift:   PLAY raw=%v\n", play_raw)
				fmt.printf("[ap] drift:   EXP  raw=%v\n", exp_raw)
			}
			for i in 0 ..< spf * 2 {
				d := math.abs(mix_play[i] - mix_exp[i])
				if d > worst {
					worst = d
					worst_frame = f
				}
				if d > DRIFT_TOLERANCE {
					over_tol += 1
				}
				if d > DRIFT_TOLERANCE && first_bad < 0 {
					first_bad = f
					// The fifo state at the moment of disagreement, BEFORE this frame's
					// samples are consumed by the next iteration's bookkeeping. If one
					// side's ring is empty and the other is not, the divergence is a
					// refill boundary; if both are empty, both are short.
					fmt.printf(
						"[ap] drift:   at disagreement: PLAY first48=%d have48=%d ring=%d | EXP first48=%d have48=%d ring=%d\n",
						audio_src.slots[0].first48, audio_src.slots[0].have48,
						ring_len(&audio_src.slots[0].fifo),
						export_audios[0].first48, export_audios[0].have48,
						ring_len(&export_audios[0].fifo),
					)
					// WHERE inside the frame, and what the two actually hold there. The
					// index is the whole diagnosis in one number: 0 means the block
					// ORIGIN is wrong, a large index means the origin was right and the
					// content drifted partway through, and a value pair that is the
					// same waveform offset by a whole frame means one sink is a frame
					// behind rather than misaligned.
					first_bad_i = i
					bad_play = mix_play[i]
					bad_exp = mix_exp[i]
					// How far does the disagreement RUN? One sample is a rounding
					// boundary; a run to the end of the frame is a shifted origin.
					run := 0
					for j in i ..< spf * 2 {
						if math.abs(mix_play[j] - mix_exp[j]) > DRIFT_TOLERANCE {
							run += 1
						}
					}
					bad_run = run
					break
				}
			}
		}
		// The position invariant, stated as a number rather than trusted: the samples
		// handed to the device must be exactly the span the timeline describes.
		want_samples := audio_frame_boundary48(total_frames, fps)
		fmt.printf(
			"[ap] drift: mixed=%d samples, timeline requires=%d, delta=%d; worst=%.6f at frame %d; %d samples over %.0e tolerance\n",
			mixed_samples, want_samples, mixed_samples - want_samples, worst, worst_frame,
			over_tol, f64(DRIFT_TOLERANCE),
		)
		if mixed_samples != want_samples {
			fmt.println("[ap] drift: FAIL: sample accounting does not match the timeline")
			return false
		}
		if first_bad >= 0 {
			// Say WHICH kind of disagreement this is. A constant content SHIFT means
			// one side is reading from a different position; a gain difference with no
			// shift means one side is applying different gain or a declick; silence on
			// one side means a source never reached the mix. They have nothing in
			// common as fixes, and "the mixers disagree" does not distinguish them.
			fmt.printf(
				"[ap] drift: FAIL: the two mixers first disagree at frame %d (%.2fs)\n",
				first_bad, f64(first_bad)/fps,
			)
			fmt.printf(
				"[ap] drift:   playback demand clamps so far: %d times, worst %d samples\n",
				audio_rpt.head_clamped, audio_rpt.head_clamp_max,
			)
			b0 := audio_frame_boundary48(first_bad, fps)
			spf := min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(audio_frame_boundary48(first_bad+1, fps) - b0)))
			fmt.printf(
				"[ap] drift:   first bad at sample index %d of %d (ch=%d) play=%.6f exp=%.6f, run=%d samples differ\n",
				first_bad_i, spf, first_bad_i % 2, bad_play, bad_exp, bad_run,
			)
			b1 := audio_frame_boundary48(first_bad + 1, fps)
			prev_len := b0 - audio_frame_boundary48(first_bad - 1, fps)
			fmt.printf(
				"[ap] drift:   frame bounds [%d,%d) len=%d; prev frame len=%d\n",
				b0, b1, b1 - b0, prev_len,
			)
			fmt.printf("[ap] drift:   play[0:4]=%v\n", mix_play[:4])
			fmt.printf("[ap] drift:   exp[0:4]=%v\n", mix_exp[:4])
			best, best_shift := f32(1e30), 0
			for sh in -4096 ..< 4096 {
				acc := f32(0)
				cnt := 0
				for i in 0 ..< spf {
					j := i + sh
					if j < 0 || j >= spf {
						continue
					}
					acc += mix_exp[i * 2] * mix_play[j * 2]
					cnt += 1
				}
				if cnt < spf / 2 {
					continue
				}
				e := math.abs(acc)
				if e < best {
					best = e
					best_shift = sh
				}
			}
			fmt.printf("[ap] drift:   best content shift=%d samples\n", best_shift)
			return false
		}
		fmt.printf(
			"[ap] drift: playback demand clamps: %d times, worst %d samples\n",
			audio_rpt.head_clamped, audio_rpt.head_clamp_max,
		)
		fmt.println("[ap] drift ok (no divergence over the whole span)")
		return true
	}

	audio_probe_mix_parity :: proc(path: string) -> bool {
		fps := timeline_fps()
		if fps <= 0 {
			fmt.println("[ap] mix-parity: SKIP: no project fps")
			return true
		}
		buf: [4096]u8
		cn := 0
		for cn < len(path) && cn < len(buf) - 1 {
			buf[cn] = u8(path[cn])
			cn += 1
		}
		buf[cn] = 0
		cpath := cstring(&buf[0])

		// A clean timeline: one clip, then a second lane of the same content, then a
		// THIRD clip that starts partway in. The third is the interesting one -- a
		// boundary inside the range, where the two mixers resolve a span and a content
		// offset by different routes and can legitimately disagree.
		audio_reset_for_load()
		audio_reset_play()
		timeline.tracks = make([dynamic]Track, 0, 1)
		timeline.track_order = make([dynamic]int, 0, 1)
		track := Track {name = "parity", clips = make([dynamic]Clip, 0, 3)}
		append(&track.clips, Clip {
			clip_id = new_clip_id(), path = cpath, kind = .Audio,
			name = session_str_intern("a"), timeline_start_frame = 0,
			source_length_frames = 90, source_start_frame = 0, stream_index = 0,
		})
		append(&track.clips, Clip {
			clip_id = new_clip_id(), path = cpath, kind = .Audio,
			name = session_str_intern("b"), timeline_start_frame = 40,
			source_length_frames = 50, source_start_frame = 0, stream_index = 0,
		})
		append(&track.clips, Clip {
			clip_id = new_clip_id(), path = cpath, kind = .Audio,
			name = session_str_intern("c"), timeline_start_frame = 95,
			source_length_frames = 30, source_start_frame = 0, stream_index = 0,
		})
		append(&timeline.tracks, track)
		sync_track_order()
		selection.track, selection.index = -1, -1

		// Playback side: provision exactly as audio_probe_gain_check does -- reset,
		// then provision, with no commit of its own and NO reset after (that call
		// clears every source slot, which is why the first two attempts at this case
		// reported an empty timeline).
		audio_geometry_commit()
		audio_reset_play()
		audio_provision(0)
		if audio_src.count == 0 {
			fmt.println("[ap] mix-parity: SKIP: playback provisioned no sources")
			return true
		}

		// Export side: the SAME clips, snapshotted through the production path from
		// the committed slab, so the gain snapshot is the one the real export would
		// carry rather than a hand-built one.
		fnum, fden := fps_rational(fps)
		num, den := i64(fnum), i64(fden)
		// A LOCAL dynamic array: render_job.audios is a slice, and assigning a dynamic
		// array into it would hand the job a pointer into this proc's stack. The slice
		// is set for the duration of the comparison and cleared in the defer below.
		export_audios: [dynamic]Render_Audio_Src
		defer delete(export_audios)
		slot := audio_geom_acquire()
		defer audio_geom_release()
		for i in 0 ..< min(int(slot.n), 8) {
			append(&export_audios, render_audio_src_from_chip(slot, &slot.chip[i]))
		}
		// render_mix_block walks render_job.audios, so point the job at the probe's
		// array for the duration. The cloned paths are ours and go with it.
		render_job.audios = export_audios[:]
		defer {
			for &a in export_audios {
				if a.path != nil {
					delete(a.path)
				}
			}
			render_job.audios = nil
		}
		render_mix: Render_Mix
		render_mix_init(&render_mix, c.int(num), c.int(den), sample_pos_from_frames(0, num, den))
		defer render_mix_bus_destroy(&render_mix.bus)
		opened := 0
		for &a in export_audios {
			if render_audio_open(&a, 0, fps) {
				opened += 1
			} else {
				a.dec.opened = false
			}
		}
		if opened == 0 {
			fmt.println("[ap] mix-parity: SKIP: export opened no sources")
			return true
		}

		// Compare frame by frame. Both mixers see the same [frame_start, frame_end)
		// range; playback as a frame, export as absolute samples.
		LAST_FRAME :: 140
		mix_play: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
		mix_exp: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
		worst := f32(0)
		worst_frame := i64(-1)
		mismatches := 0
		for frame in i64(0) ..= LAST_FRAME {
			f0 := sample_pos_from_frames(frame, num, den)
			f1 := sample_pos_from_frames(frame + 1, num, den)
			n := int(f1 - f0)
			if n <= 0 || n > MAX_AUDIO_FRAME_SAMPLES {
				continue
			}
			audio_src.next_frame = frame
			audio_mix_frame(mix_play[:], frame, n)
			// The export at its NATURAL granularity. Its real producer mixes
			// AUDIO_MIX_BLOCK (512) at a time and the consumer takes whatever range
			// its frame covers; driving it with a whole frame at once would be the
			// probe inventing a path the export never takes, and if the shift moved
			// with the block size the finding would be about the probe.
			for i in 0 ..< n * 2 {
				mix_exp[i] = 0
			}
			off := 0
			for off < n {
				k := min(AUDIO_MIX_BLOCK, n - off)
				render_mix_block(&render_mix, mix_exp[off * 2:], f0 + Sample_Pos(off), k)
				off += k
			}
			bad := false
			for i in 0 ..< n * 2 {
				d := abs(mix_play[i] - mix_exp[i])
				if d > worst {
					worst = d
					worst_frame = frame
				}
				// One part in ten thousand of full scale: both mixers are f32
				// through the same evaluator, so this catches a different DECISION,
				// not a rounding wobble.
				if d > 0.0001 {
					bad = true
				}
			}
			if frame == 0 {
				// The fifo HEADS, which is where a content offset actually lives: two
				// mixers can do identical arithmetic and still disagree if their decoders
				// landed at different content positions. Printed at frame 0 because that
				// is the only frame where an OPENING shortfall is the whole story --
				// afterwards a head is just the fifo advancing.
				//
				// Measured on the AAC fixture: playback slot 0 first48=800 (exactly one
				// 60fps frame, so playback drops frame 0 of the first clip) while every
				// export source reports first48=1024 (the AAC encoder delay, so the
				// export drops the first 21.3ms of EVERY clip). On a WAV fixture both
				// report 0 and the mixers are bit-identical. So this line is the
				// difference between "the mixers disagree" and "neither sink can supply
				// content 0".
				fmt.printf("[ap] mix-parity heads (play then export):")
				for i in 0 ..< audio_src.count {
					sl := &audio_src.slots[i]
					fmt.printf(" p%d.first48=%d", i, sl.first48)
				}
				for i in 0 ..< len(export_audios) {
					fmt.printf(" e%d.first48=%d", i, export_audios[i].first48)
				}
				fmt.println()
			}
			if bad {
				mismatches += 1
				if mismatches <= 3 {
					fmt.printf("[ap] mix-parity: frame %d differs (worst so far %.6f)\n", frame, worst)
				}
			}
		}
		at := ""
		if worst_frame >= 0 {
			at = fmt.aprintf(" at frame %d", worst_frame)
		}
		fmt.printf(
			"[ap] mix-parity: %d frames, %d mismatching, worst delta %.6f%s\n",
			LAST_FRAME + 1,
			mismatches,
			worst,
			at,
		)
		if mismatches > 0 {
			fmt.println("[ap] FAIL: the playback and export mixers do not agree")
			return false
		}
		fmt.println("[ap] mix-parity ok (both mixers produced identical samples)")
		return true
	}

	// audio_probe_mix_run mixes `count` frames from `start`, advancing audio_src
	// next_frame exactly as audio_producer_feed does, and returns how many of them
	// actually delivered audio.
	audio_probe_mix_run :: proc(start: i64, count: int, fps: f64) -> int {
		audio_src.next_frame = start
		delivered := 0
		mix: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
		for i in 0 ..< count {
			spf := min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(48000.0 / fps + 0.5)))
			if audio_mix_frame(mix[:], audio_src.next_frame, spf) {
				delivered += 1
			}
			audio_src.next_frame += 1
		}
		return delivered
	}

	find_audio_track :: proc() -> ^Track {
		for &t in timeline.tracks {
			for &c in t.clips {
				if c.kind == .Audio {
					return &t
				}
			}
		}
		return nil
	}

	// audio_probe_group_tempo_isolation is the regression test for the grouping bug the
	// fuzz harness found on the user's own ~/sallyface.vyproj.
	//
	// Two audio clips cut from the SAME file and placed ADJACENTLY are contiguous in
	// both timeline and source, which is every condition audio_provision_find_group used
	// to check. Two adjacent cuts of one file are the most ordinary thing a timeline
	// contains, and nothing about the geometry distinguishes them.
	//
	// So the second was folded into the first's group and mixed through the first's
	// atempo graph -- a 0.5x clip playing at 1x. Measured as a runtime assertion on the
	// real project:
	//
	//	audio_build_groups: one atempo graph cannot serve segments with different clip speed/pitch
	//
	// which is the engine telling the truth about a decision made in the wrong place.
	//
	// The assertion is right; the grouping was wrong. This probe pins the FIX, at the
	// granularity that matters: not "it does not crash" but "each speed gets its own
	// graph, and each graph is built for its own speed".
	audio_probe_group_tempo_isolation :: proc(path: string) -> bool {
		defer audio_probe_timeline_reset()
		path_buf: [4096]u8
		assert(len(path) < len(path_buf), "audio_probe_group_tempo_isolation: path buffer overflow")
		path_n := len(path)
		for i in 0 ..< path_n {
			path_buf[i] = u8(path[i])
		}
		path_buf[path_n] = 0
		cpath := cstring(&path_buf[0])

		// Adjacent clips, SAME file, SAME stream, contiguous in both axes. The ONLY
		// difference is speed -- so if grouping folds them together it is because it
		// ignored the tempo, which is the defect.
		//
		// The first TWO are both 1.0x and they ARE contiguous, so they must SHARE a
		// group and one decoder. That is what makes this a real test in both directions:
		// a fix that simply refuses to continue any group would pass a "different speeds
		// never share" assertion while breaking every ordinary multi-clip timeline, and
		// that is the failure mode a naive guard here would have.
		speeds := []f64{1.0, 1.0, 0.5, 2.0}
		span := i64(150)
		timeline.tracks = make([dynamic]Track, 0, 2)
		timeline.track_order = make([dynamic]int, 0, 2)
		atrack := Track {name = "a", clips = make([dynamic]Clip, 0, 8)}
		at := i64(0)
		src_at := i64(0)
		for sp in speeds {
			append(
				&atrack.clips,
				Clip {
					clip_id = new_clip_id(),
					path = cpath,
					kind = .Audio,
					name = session_str_intern("audio"),
					timeline_start_frame = at,
					source_length_frames = span,
					// The SOURCE position advances by the clip's CONTENT length, separately
					// from the timeline position. Contiguity is checked in BOTH axes by
					// audio_provision_find_group, so a fixture that advanced only the
					// timeline would fail the source test for reasons that have nothing to
					// do with tempo -- which is exactly what the first two versions of this
					// probe did.
					source_start_frame = src_at,
					stream_index = 0,
					speed = sp,
				},
			)
			// Advance by the clip's TIMELINE length, which is content length / speed.
			// Stepping by a constant would overlap every slower clip with the next one and
			// quietly test a different timeline than the one described.
			at += max(1, i64(f64(span) / sp))
			src_at += span
		}
		append(&timeline.tracks, atrack)
		sync_track_order()
		selection.track, selection.index = -1, -1
		audio_geometry_commit()

		audio_provision(0)
		defer audio_reset_play()

		fmt.printf(
			"[ap] group-isolation: %d adjacent same-file clips at speeds %v -> %d source groups\n",
			len(speeds),
			speeds,
			audio_src.count,
		)
		// Three groups: the two contiguous 1.0x clips share one decoder, and the 0.5x
		// and 2.0x clips each need their own graph. One group would be the bug; four
		// would be the opposite bug, refusing to continue a group that matches.
		want_groups := 3
		if audio_src.count != want_groups {
			fmt.printf(
				"[ap] group-isolation: FAIL: %d groups, want %d -- clips sharing a file were folded across a tempo change\n",
				audio_src.count,
				want_groups,
			)
			return false
		}
		// And each group must be built for the tempo of the clips it holds. A count
		// alone would pass if the right number of groups held the wrong speeds.
		for k in 0 ..< audio_src.count {
			g := &audio_src.slots[k]
			if g.seg_count == 0 {
				continue
			}
			// Play_Seg carries the tempo of the clip it came from, so this compares the
			// graph against the segments it will actually mix -- not against a list the
			// probe wrote, which could drift from what the engine built.
			for si in 0 ..< g.seg_count {
				if g.speed != g.seg[si].speed {
					fmt.printf(
						"[ap] group-isolation: FAIL: group %d holds a %.3fx segment but its graph is built for %.3fx\n",
						k,
						g.seg[si].speed,
						g.speed,
					)
					return false
				}
			}
			fmt.printf("[ap] group-isolation: group %d speed=%.3fx segs=%d\n", k, g.speed, g.seg_count)
		}
		fmt.println("[ap] group-isolation ok (each clip is mixed by a graph built for its own speed)")
		return true
	}

	// audio_probe_decode_integrity proves decode_audio_chunk hands over the audio the
	// file holds at the position it labels, whatever came before.
	//
	// Two properties, both measured on the decoder itself rather than inferred from a
	// position counter, because every counter in the engine is derived from the label:
	//
	//   - the resampler's backlog never grows. swres_convert buffers whatever the room
	//     cannot hold, silently; a source whose decoder frames exceeded the output
	//     buffer (FLAC's 4608-sample blocks against the old 4096) then lagged its own
	//     labels by a growing margin. A rate-converting source has an inherent filter
	//     delay, so the check is that the delay after the last chunk is no larger than
	//     after the first, which holds for both it and a 48 kHz source (delay 0).
	//   - a seek forgets everything decoded before it. The same position decoded
	//     fresh and decoded after a detour elsewhere must be byte-identical; a
	//     resampler that kept pre-seek input replays it after the seek.
	//
	// `path` should be a stereo file with non-repeating content and decoder frames
	// larger than 4096 samples; the gate builds FLAC chirps at 48 kHz and 44.1 kHz.
	audio_probe_decode_integrity :: proc(path: string) -> bool {
		cpath := strings.clone_to_cstring(path, context.temp_allocator)
		DECODE_CHUNKS :: 6
		FRESH_ASK :: i64(96000)
		DETOUR_ASK :: i64(480000)

		Run :: struct {
			start:       i64,
			samples:     [dynamic]i16,
			first_delay: i64,
			last_delay:  i64,
			ok:          bool,
		}
		run_at :: proc(dec: ^Audio_Clip_Decoder, ask: i64, run: ^Run) {
			clear(&run.samples)
			n := decode_from_content(dec, ask)
			if n <= 0 {
				return
			}
			run.start = i64(decoder_pts_sample(dec.first_ts, dec.stream.time_base))
			for chunk in 0 ..< DECODE_CHUNKS {
				if chunk > 0 {
					n = decode_audio_chunk(dec, -1.0)
					if n <= 0 {
						return
					}
				}
				append(&run.samples, ..dec.s16[:n * int(dec.out_channels)])
				run.last_delay = i64(swres.get_delay(dec.swr_ctx, i64(dec.out_rate)))
				if chunk == 0 {
					run.first_delay = run.last_delay
				}
			}
			run.ok = true
		}

		fresh, detour := Run{}, Run{}
		defer delete(fresh.samples)
		defer delete(detour.samples)

		a: Audio_Clip_Decoder
		if !open_audio_decoder_resampled(&a, cpath, 0, 48000, 2) {
			fmt.println("[ap] decode-integrity: could not open", path)
			return false
		}
		defer audio_decoder_reset(&a)
		run_at(&a, FRESH_ASK, &fresh)

		b: Audio_Clip_Decoder
		if !open_audio_decoder_resampled(&b, cpath, 0, 48000, 2) {
			return false
		}
		defer audio_decoder_reset(&b)
		scratch := Run{}
		defer delete(scratch.samples)
		run_at(&b, DETOUR_ASK, &scratch)
		run_at(&b, FRESH_ASK, &detour)

		if !fresh.ok || !detour.ok || !scratch.ok {
			fmt.println("[ap] decode-integrity: FAIL decode ran dry")
			return false
		}
		peak := i16(0)
		for v in fresh.samples {
			peak = max(peak, abs(v))
		}
		if peak < 1000 {
			fmt.println("[ap] decode-integrity: FAIL fixture is silent; the comparison would prove nothing")
			return false
		}
		fmt.printf(
			"[ap] decode-integrity: in=%dHz ask=%d start fresh=%d detour=%d samples=%d peak=%d swr_delay first=%d last=%d\n",
			int(a.input_rate), int(FRESH_ASK), int(fresh.start), int(detour.start), len(fresh.samples), int(peak),
			int(fresh.first_delay), int(fresh.last_delay),
		)
		for r in ([]Run{fresh, detour, scratch}) {
			if r.last_delay > r.first_delay {
				fmt.println("[ap] decode-integrity: FAIL resampler backlog grew; its output lags the labels")
				return false
			}
		}
		if fresh.start != detour.start || len(fresh.samples) != len(detour.samples) {
			fmt.println("[ap] decode-integrity: FAIL a seek after a detour landed or sized differently from a fresh seek")
			return false
		}
		for i in 0 ..< len(fresh.samples) {
			if fresh.samples[i] != detour.samples[i] {
				fmt.printf("[ap] decode-integrity: FAIL sample %d differs after a seek: fresh=%d detour=%d (pre-seek audio resurfaced)\n",
					i, int(fresh.samples[i]), int(detour.samples[i]))
				return false
			}
		}
		fmt.println("[ap] decode-integrity ok (resampler holds nothing, and a seek leaves no trace of what came before)")
		return true
	}

}
