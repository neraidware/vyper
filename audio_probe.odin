package main

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
		clone.clip_id = new_clip_id()
		clone.link_id = video_link
		clone.markers = nil
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
		name = "audio",
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
	gain_frames := i64(120)
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
	peak_unity := audio_probe_mix_peak(mix[:], 0, gain_frames, fps)
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
	peak_live := audio_probe_mix_peak(mix[:], gain_frames, gain_frames, fps)
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
				name = "audio",
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
	return true
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
				name = "clip",
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
