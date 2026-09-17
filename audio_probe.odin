package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import sdl "vendor:sdl3"

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

	async_import_mode = false
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
		selected_track = track_index_of(tr)
		selected_index = clip_index_on_track(tr, clip)
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
	slot := &audio_geom[sync.atomic_load(&audio_geom_idx)]
	fmt.printf("[ap] geometry chips=%d (geom cap %d)\n", slot.n, AUDIO_GEOM_MAX_CLIPS)

	// Provision at the timeline start: the worst case, since every segment is
	// in the future and each wants its own decoder.
	audio_trace = true
	prov_t0 := sdl.GetTicksNS()
	audio_provision(0)
	prov_ms := f64(sdl.GetTicksNS()-prov_t0) / 1e6
	fmt.printf(
		"[ap] audio_provision took %.1f ms, play_src_count=%d (MAX_PLAY_AUDIO=%d)\n",
		prov_ms,
		play_src_count,
		MAX_PLAY_AUDIO,
	)
	seg_total := 0
	for k in 0 ..< play_src_count {
		seg_total += play_srcs[k].seg_count
	}
	fmt.printf("[ap] provisioned %d groups / %d segments (chips=%d)\n", play_src_count, seg_total, slot.n)
	fps := timeline_fps()
	for k in 0 ..< play_src_count {
		s := &play_srcs[k]
		start_a, start_s, len_a := i64(0), i64(0), i64(0)
		if first := play_src_first_seg_at(s, 0); first != nil {
			start_a, start_s, len_a = first.start_a, first.start_s, first.len_a
		}
		expected := i64(f64(start_s) * 48000.0 / fps)
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
		for k in 0 ..< play_src_count {
			s := &play_srcs[k]
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
	audio_trace = true
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

	audio_reset_play()
	return 0
}
