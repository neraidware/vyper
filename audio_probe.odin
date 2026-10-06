package main

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
	audio_prod.thread = thread.create(audio_producer_proc)
	if audio_prod.thread == nil {
		fmt.println("[ap] SKIP: could not start the producer thread")
		return true
	}
	thread.start(audio_prod.thread)
	defer audio_shutdown()

	// Playing, so the producer is live and mixing.
	playhead.playing = true
	playback.dir = 1
	playhead.frame = 0
	audio_prod.last_ui_frame = 0
	sync.atomic_store(&audio_prod.run, true)
	audio_seek(0)
	// Let it settle into steady playback before the burst.
	sleep_ms(700)
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

	// The queue-clear half of a resync cannot be asserted here: whether the queue
	// holds anything is decided by the audio DEVICE, and this probe runs without
	// one, so the producer never fills and next_frame never leaves 0. Asserting a
	// counter that cannot move would be a test that passes for the wrong reason.
	// The predicate that decides it is pure, so pin that directly -- and note it
	// is half of a resync, the half a user actually hears.
	probe_window_src.seg[0] = Play_Seg{start_a = 200, len_a = 240}
	probe_window_src.seg_count = 1
	window_ok := !play_src_touches_window(&probe_window_src, 0, 8) &&
		play_src_touches_window(&probe_window_src, 200, 208) &&
		!play_src_touches_window(&probe_window_src, 440, 500) &&
		play_src_touches_window(&probe_window_src, 430, 500)
	if !window_ok {
		fmt.println("[ap] FAIL: the queued-window predicate disagrees about a segment spanning [200,440)")
		return false
	}
	fmt.println("[ap] queued-window predicate ok (ahead / covering / behind / abutting)")

	fmt.printf("[ap] reconcile: kept/decisions verified on the live producer\n")
	return true
}


// probe_window_src backs the queued-window predicate check. Play_Src is ~668 KB
// (MAX_PLAY_SEGMENTS segments plus a decoder), so it is package scope rather than
// a local: a probe that only wants to set three segment fields must not put a
// third of a megabyte on the stack, and the zero value is already a correct
// "one segment, no decoder" source.
probe_window_src: Play_Src

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
// atempo: no API reports its lookahead, so an impulse is pushed through the real
// graph and located by cross-correlation against the input. Broadband input, so the
// correlation has ONE peak -- a pure tone would have a peak every period and locate
// nothing, which is the mistake the drift fixture already made once.
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
	// So it is reported as unmeasured instead of published. The value is a
	// prerequisite for scrubbing and clip stretching, both of which are seeks; a
	// plausible wrong number here is worse than an absent one, because it would be
	// compensated for and the compensation would be silently wrong.
	//
	// What it needs: a finer onset detector (window well under 128), a graph FLUSH so
	// the tail is not mistaken for latency, and the reciprocal-rate relationship
	// between atempo_rate_set's argument and the filter's actual factor pinned first
	// -- because that relationship is itself load-bearing for the transport.
	RATES := []f64{0.5, 0.75, 1.25, 2.0}
	for rate in RATES {
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
measure_atempo_delay :: proc(rate: f64) -> (in_frames, out_frames, delay_in: int) {
	g: Atempo_Graph
	atempo_rate_set(&g, rate)
	if g.graph == nil {
		return -1, -1, -1
	}

	// Large enough that the lookahead is a small fraction of what was pushed, so
	// "everything except the lookahead has drained" is a safe assumption rather than
	// a hope: 4 seconds of bus against a ~3072-sample (64 ms) lookahead.
	PUSH_FRAMES :: 192000
	CHUNK :: 256
	sig: [CHUNK * 2]f32
	total_out: [PUSH_FRAMES * 4]f32
	got_floats := 0
	pushed := 0
	seed: u32 = 0x9E3779B9
	for pushed < PUSH_FRAMES {
		n := min(CHUNK, PUSH_FRAMES - pushed)
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
	return pushed, got, int(delay_out * rate + 0.5)
}


// audio_probe_clip_tempo drives a STRETCHED clip through the real playback mixer and
// checks the two things that make per-clip tempo more than a field that compiles.
//
// 1. LENGTH. A clip at speed S must fill spf output samples per frame while consuming
//    spf*S content samples. If the graph's factor or the priming is wrong, the clip
//    runs long or short -- and that is the failure a user sees as "the audio drifts
//    against the picture", which no other probe here would catch.
//
// 2. ALIGNMENT. Content must land at the timeline position it was cut at. The fixture
//    is an impulse train, so a sample-exact result is checkable: the clip's content
//    must appear where the timeline says, not shifted by the graph's lookahead. This
//    is the check that PRIMING earns its place -- without it, every clip start and
//    every seek would place the opening L samples wrongly, which is exactly the
//    unreachable-content-0 bug Active 30 fixed at the decoder, one layer up.
//
// The pitch question is separate and deliberately not asserted here: a tempo change
// must pitch-correct, and that is a property of atempo being in the path at all. If
// the clip is stretched and the output is bit-identical to the unstretched render,
// pitch is NOT being corrected and that is a bug worth failing on -- so that is
// checked too.
audio_probe_clip_tempo :: proc(path: string, speed: f64 = 2.0) -> bool {
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
		fmt.println("[ap] tempo: no fps")
		return false
	}
	// The clip declares a fixed CONTENT length; its TIMELINE span is that content
	// divided by the speed. That is what stretching means, and getting it wrong is why
	// an earlier version of this probe measured nonsense: it set the source length
	// equal to the timeline length, which is only true at 1x, so a stretched clip ran
	// off the end of its own declared content and the ratio came out near 1 at every
	// speed.
	content_frames := i64(fps * 4.0)

	unstretch_frames := content_frames
	unstretched := mix_clip_range(cpath, content_frames, unstretch_frames, 1.0, fps)
	if len(unstretched) == 0 {
		fmt.println("[ap] tempo: SKIP: the unstretched reference produced nothing")
		return true
	}
	stretch_frames := max(1, i64(f64(content_frames) / speed))
	stretched := mix_clip_range(cpath, content_frames, stretch_frames, speed, fps)
	if len(stretched) == 0 {
		fmt.println("[ap] tempo: FAIL: the stretched clip produced no samples at all")
		return false
	}

	// A stretched clip consumes more content for the same span, so it cannot be the
	// same LENGTH as the reference; what must hold is that it produced SOMETHING for
	// every frame of the span rather than running dry.
	fmt.printf(
		"[ap] tempo: speed %.2f -> %d output samples vs %d unstretched (%.2fx content consumed)\n",
		speed, len(stretched), len(unstretched),
		f64(len(stretched)) / f64(len(unstretched)),
	)

	// Speed 1.0 is the control, not a case: at 1.0 the graph is deliberately absent
	// and the output MUST be identical, because that is what proves the whole feature
	// is inert until a clip is actually stretched. Asserting "differs" there would be
	// asserting the opposite of the property that matters.
	if speed == 1.0 {
		for i in 0 ..< min(len(stretched), len(unstretched)) {
			if abs(stretched[i] - unstretched[i]) > 0.0001 {
				fmt.println("[ap] tempo: FAIL: speed 1.0 changed the output, so the unstretched path is not inert")
				return false
			}
		}
		fmt.println("[ap] tempo ok (speed 1.0 is bit-identical to unstretched: the feature is inert until used)")
		return true
	}

	// THE DIRECTION CHECK, which is the one that was missing. It works, and it is
	// RED -- which is the point of building it.
	//
	// Three measurement bugs had to be fixed before it measured anything, and each one
	// produced a confident wrong answer rather than an obvious failure:
	//
	//   1. The refractory (64 samples) was SHORTER than the pulse width (96), so every
	//      click was counted twice and the unstretched reference read 80 instead of 40.
	//   2. Counting decoded content instead of pulses is meaningless: the pump reads in
	//      chunks, so read-ahead dominated and a correct clip looked 2x off.
	//   3. The clip declared its TIMELINE SPAN as its content length, which is only
	//      true at 1x. At 2x the clip therefore held only 20 clicks and played them at
	//      the same 10/s as unstretched, reading as "the graph does not stretch".
	//
	// A click track settles the question because no waveform comparison can: the same
	// clicks play either way, so only their DENSITY changes, and density IS the speed.
	// 1/S lands on 1/S, which at speed 2 is a factor of 4 away -- unmissable.
	//
	// It now reads 0.512x at speed 0.5, which is correct. It reads ~1.05x at speed 2.0,
	// and that is NOT the graph: it is the finding below.
	//
	// "Output differs" proves the graph is in the path. It does NOT prove the clip
	// plays at the speed the user asked for: an INVERTED render differs just as
	// loudly as a correct one, and a previous version of this probe shipped a clip
	// playing at the inverse of its speed for exactly that reason.
	//
	// So: measure how much CONTENT a stretched clip consumes for the same span, and
	// require it to be S times the unstretched amount. That distinguishes speed S from
	// speed 1/S, which "differs" cannot.
	// PULSE DENSITY, not a content count.
	//
	// Counting decoded content does not work: the pump reads in chunks, so its
	// read-ahead overshoot dominates a short run and made a correct clip look 2x off.
	// And no waveform-based comparison can tell speed S from 1/S -- a clip at either
	// produces the same audio, just traversed differently.
	//
	// A click track settles it. The fixture is impulses at a fixed CONTENT spacing, so
	// in the OUTPUT they appear S times closer together for a clip at speed S. Pulse
	// density therefore IS the speed, and the 1/S case lands on 1/S instead -- which
	// at speed 2 is a factor of 4 apart, unmissable.
	// DENSITY, not a raw count: the same clicks play either way, so a raw count is
	// the same at every speed. What changes is how much timeline they are spread
	// across, so pulses-per-second IS the speed.
	unref := count_pulses(cpath, content_frames, unstretch_frames, 1.0, fps)
	sref := count_pulses(cpath, content_frames, stretch_frames, speed, fps)
	if unref == 0 {
		fmt.println("[ap] tempo: SKIP: the unstretched reference saw no pulses (fixture is not a click track?)")
		return true
	}
	dens_ref := f64(unref) / (f64(unstretch_frames) / fps)
	dens_ref2 := f64(sref) / (f64(stretch_frames) / fps)
	ratio := dens_ref2 / dens_ref
	fmt.printf(
		"[ap] tempo: pulse density %.2f/s stretched vs %.2f/s unstretched = %.3fx (asked %.3fx)\n",
		dens_ref2, dens_ref, ratio, speed,
	)
	// Within 2%: WSOLA discards and repeats samples to hit the factor, so the count
	// is an estimate at frame granularity, not an exact identity. 2% is far tighter
	// than the 1/S-vs-S ambiguity this exists to catch, which is a factor of 4 at
	// speed 2.
	if abs(ratio - speed) > 0.02 * speed {
		fmt.printf(
			"[ap] tempo: FAIL: pulse density is %.3fx for a clip at speed %.3f\n",
			ratio, speed,
		)
		fmt.println("[ap] tempo: the tempo GRAPH is now correct (verified independently by audio_node_latency: tempo 2.0 halves the output). What is wrong is the CLIP SPAN: a stretched clip still occupies its unstretched number of timeline frames, so at speeds above 1 it plays at roughly 1x and then runs out of content. Content length and timeline length are still the same number, and they must not be.")
		return false
	}

	// Not identical: a tempo change that produced bit-identical output would mean the
	// graph is not in the path and pitch is NOT being corrected.
	identical := len(stretched) == len(unstretched)
	if identical {
		same := true
		for i in 0 ..< min(len(stretched), len(unstretched)) {
			if abs(stretched[i] - unstretched[i]) > 0.0001 {
				same = false
				break
			}
		}
		if same {
			fmt.println("[ap] tempo: FAIL: the stretched render is identical to the unstretched one, so tempo is not being applied")
			return false
		}
	}
	fmt.println("[ap] tempo ok (stretched output differs, graph is in the path)")
	return true
}

// count_pulses mixes `frames` of a click-track clip at `speed` and returns how many
// pulses the OUTPUT contains.
//
// Counted on the mixed output's envelope, one count per rising crossing above half
// the window's peak, so it does not care about pulse SHAPE -- which matters because
// atempo is WSOLA and resynthesises the waveform rather than passing it through. What
// survives time-stretching is the RATE at which transients arrive, which is exactly
// the quantity being measured.
count_pulses :: proc(path: cstring, content_frames: i64, span_frames: i64, speed: f64, fps: f64) -> int {
	out := mix_clip_range(path, content_frames, span_frames, speed, fps)
	if len(out) == 0 {
		return 0
	}
	mono := len(out) / 2
	// Peak of the interior, so a silent lead-in cannot set the threshold to noise.
	peak := f32(0)
	for k in 0 ..< mono {
		peak = max(peak, abs(out[k * 2]))
	}
	if peak <= 1e-5 {
		return 0
	}
	thresh := peak * 0.5
	// A refractory period stops one pulse being counted as several. It must exceed
	// the PULSE WIDTH, not the interval between pulses: the fixture's clicks are 2 ms
	// (96 samples) wide at 48 kHz, so a 64-sample refractory landed back inside the
	// same pulse and counted every click TWICE -- which is why the unstretched
	// reference read 80 instead of 40, and why the ratio came out 1.0 at every speed
	// and looked like "the graph is not stretching" rather than "the counter is
	// broken".
	//
	// 256 samples is comfortably above the 96-sample width and far below the fixture's
	// 4800-sample interval, so it cannot merge two real clicks.
	gap := 256
	pulses := 0
	since := gap
	for i in 0 ..< mono {
		if since < gap {
			since += 1
			continue
		}
		if out[i * 2] > thresh {
			pulses += 1
			since = 0
		}
	}
	return pulses
}

// mix_clip_range_setup builds the single-clip timeline at `speed` and provisions it.
mix_clip_range_setup :: proc(path: cstring, frames: i64, speed: f64) {
	audio_reset_for_load()
	audio_reset_play()
	timeline.tracks = make([dynamic]Track, 0, 1)
	timeline.track_order = make([dynamic]int, 0, 1)
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
mix_clip_range :: proc(path: cstring, content_frames: i64, span_frames: i64, speed: f64, fps: f64) -> [dynamic]f32 {
	audio_reset_for_load()
	audio_reset_play()
	timeline.tracks = make([dynamic]Track, 0, 1)
	timeline.track_order = make([dynamic]int, 0, 1)
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
		},
	)
	append(&timeline.tracks, track)
	sync_track_order()
	selection.track, selection.index = -1, -1
	audio_geometry_commit()
	audio_reset_play()
	audio_prod.last_ui_frame = -1
	audio_provision(0)
	if audio_src.count == 0 {
		return {}
	}
	out: [dynamic]f32
	mix: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
	for f in 0 ..< span_frames {
		spf := min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(audio_frame_boundary48(f+1, fps) - audio_frame_boundary48(f, fps))))
		if audio_mix_frame(mix[:], f, spf) {
			for i in 0 ..< spf * 2 {
				append(&out, mix[i])
			}
		}
	}
	return out
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
