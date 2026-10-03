package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

// INAUDIBLE_PEAK_FS is the peak S16 amplitude below which decoded audio counts
// as silence (~-36 dBFS). ffmpeg's volumedetect reports the bug's regions as
// -60 dB mean, so this floor and ffmpeg agree on where the defect lives.
INAUDIBLE_PEAK_FS :: 512

// Fixture geometry. The tone starts after the silent head so that "the offset
// moved to an earlier part of the file" is audible rather than merely wrong:
// the bug made a clip read the silent head, which is exactly what the original
// report was.
AR_FIXTURE_RATE      :: f64(12) // the rate the fixture project is authored at
AR_FIXTURE_NEW_RATE  :: f64(60) // the rate the user switches to (the defect)
AR_FIXTURE_SILENT_S  :: f64(1.2) // silent head length
AR_FIXTURE_TONE_HZ   :: f64(1000)
AR_FIXTURE_SECONDS   :: f64(6)
AR_FIXTURE_SRC_START :: i64(30) // 30 frames at 12fps == 2.5s == inside the tone
AR_FIXTURE_SRC_LEN   :: i64(24) // 2s at 12fps

// ar_measure_peak commits the current timeline geometry, provisions at
// play_frame, and measures the peak S16 amplitude the real playback decode path
// produces there. Returns (peak, samples, covered).
ar_measure_peak :: proc(play_frame: i64) -> (peak, samples: int, covered: bool) {
	audio_geometry_commit()
	audio_provision(play_frame)
	for k in 0 ..< audio_src.count {
		s := &audio_src.slots[k]
		if !s.dec.opened || play_src_seg_at(s, play_frame) == nil {
			continue
		}
		covered = true
		for pass in 0 ..< 4 {
			n := decode_audio_chunk(&s.dec, -1.0)
			if n <= 0 {
				break
			}
			for i in 0 ..< n * 2 {
				a := int(s.dec.s16[i])
				if a < 0 {
					a = -a
				}
				if a > peak {
					peak = a
				}
			}
			samples += n
		}
		if samples > 0 {
			return
		}
	}
	return
}

// ar_simulate_preview_mix walks the given frames through audio_mix_frame -- the
// exact call the playback audio thread makes per frame -- and measures the peak
// amplitude of the MIXED buffer, not merely whether the mix reported that it
// delivered something. A frame can "deliver" pure zeroes, which is what a
// mis-pointed source looks like from the device's side, so only the buffer's
// amplitude distinguishes them.
//
// Returns (frames, frames_with_signal, peak).
ar_simulate_preview_mix :: proc(from, to: i64) -> (frames, with_signal: int, peak: int) {
	fps := timeline_fps()
	mix: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
	for f := from; f < to; f += 1 {
		spf := 1
		if fps > 0 {
			b0 := audio_frame_boundary48(f, fps)
			b1 := audio_frame_boundary48(f + 1, fps)
			spf = min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(b1 - b0)))
		}
		_ = audio_mix_frame(mix[:], f, spf)
		frames += 1
		fp := 0
		for i in 0 ..< spf * 2 {
			v := mix[i]
			if v < 0 {
				v = -v
			}
			a := int(v * 32767.0)
			if a > fp {
				fp = a
			}
		}
		if fp > peak {
			peak = fp
		}
		if fp >= INAUDIBLE_PEAK_FS {
			with_signal += 1
		}
	}
	return
}

// ar_report_rate_invariance asserts the invariant the whole fix rests on: the
// resolved source start of a clip must not move when the clock does.
ar_report_rate_invariance :: proc(c: ^Clip, pinned: f64) -> bool {
	ok := true
	if !(c.audio_src_rate > 0) {
		fmt.println("[ar-probe] FAIL: audio clip has no pinned audio_src_rate")
		return false
	}
	OTHER_CLOCKS :: []f64{12, 24, 30, 60, 120}
	for other in OTHER_CLOCKS {
		got := audio_content_sec(0, c.source_start_frame, c.audio_src_rate, other)
		if math.abs(got - pinned) > 1e-9 {
			fmt.printf(
				"[ar-probe] FAIL: source start moved with the clock: at %v fps got %.6fs, pinned %.6fs\n",
				other,
				got,
				pinned,
			)
			ok = false
		}
	}
	return ok
}

// Headless probe for "changing the project frame rate silences audio clips".
//
//   VYPER_AUDIO_RATE_PROBE="<project.vyproj>|<fps>|<out.mp4>"  (a real project)
//   VYPER_AUDIO_RATE_FIXTURE="<scratch.wav>|<out.mp4>"          (self-contained)
//
// An audio clip's source offset used to be divided by the CURRENT project rate,
// so switching a 12fps project to 60fps moved an offset of 35 frames from
// 2.917s to 0.583s -- into the silent head of the file. The offset is now pinned
// per clip (Clip.audio_src_rate).
//
// The probe asserts that invariance DIRECTLY (the resolved source start must be
// identical at 12/24/30/60/120 fps), which a loudness check alone cannot do: a
// project whose clips happen to sit on non-silent audio would keep passing even
// after the pin silently reverted.
audio_rate_probe_run :: proc(v: string) {
	parts := strings.split(v, "|")
	if len(parts) < 1 || parts[0] == "" {
		fmt.println("[ar-probe] need VYPER_AUDIO_RATE_PROBE=\"<project.vyproj>|<fps>|<out.mp4>\"")
		os.exit(2)
	}
	if perr := project_file_open(parts[0]); perr != "" {
		fmt.println("[ar-probe] FAIL: open:", perr)
		os.exit(3)
	}
	fmt.printf(
		"[ar-probe] loaded %s: project.frame_rate=%v timeline.frame_rate=%v project_fps=%v\n",
		parts[0],
		project.frame_rate,
		timeline.frame_rate,
		project_fps(),
	)
	if len(parts) >= 2 && parts[1] != "" {
		fps, ok := strconv.parse_f64(parts[1])
		if !ok || fps <= 0 {
			fmt.println("[ar-probe] FAIL: bad fps:", parts[1])
			os.exit(2)
		}
		project.frame_rate = fps
		fmt.printf("[ar-probe] set project fps -> project_fps=%v timeline_fps=%v\n", project_fps(), timeline_fps())
	}
	fps := timeline_fps()
	fail := false
	audio_rpt.trace = true

	total, inaudible := 0, 0
	for ti in 0 ..< len(timeline.tracks) {
		for ci in 0 ..< len(timeline.tracks[ti].clips) {
			ac := &timeline.tracks[ti].clips[ci]
			if ac.kind != .Audio {
				continue
			}
			total += 1
			pinned := audio_source_start_sec(ac.source_start_frame, ac.audio_src_rate)
			if !ar_report_rate_invariance(ac, pinned) {
				fail = true
			}
			fmt.printf(
				"[ar-probe] clip %q a=[%d,%d) s_start=%d pinned_rate=%v -> reads %.3f..%.3fs of the file\n",
				string(ac.path),
				ac.timeline_start_frame,
				ac.timeline_start_frame + ac.source_length_frames,
				ac.source_start_frame,
				ac.audio_src_rate,
				pinned,
				audio_content_sec(ac.source_length_frames, ac.source_start_frame, ac.audio_src_rate, fps),
			)
			play_frame := ac.timeline_start_frame + ac.source_length_frames / 2
			peak, got, covered := ar_measure_peak(play_frame)
			fmt.printf(
				"[ar-probe]   frame %d: %d sample-frames peak=%d (%.1f%% FS) -> %s\n",
				play_frame,
				got,
				peak,
				f64(peak) * 100.0 / 32768.0,
				peak >= INAUDIBLE_PEAK_FS ? "AUDIBLE" : "IN-AUDIBLE",
			)
			// The real preview path: audio_mix_frame per frame, measuring the
			// mixed buffer's amplitude rather than trusting the delivered flag.
			audio_provision(ac.timeline_start_frame)
			mf, ms, mp := ar_simulate_preview_mix(ac.timeline_start_frame, ac.timeline_start_frame + ac.source_length_frames)
			fmt.printf(
				"[ar-probe]   preview mix: %d/%d frames carried signal, peak=%d (%.1f%% FS)\n",
				ms,
				mf,
				mp,
				f64(mp) * 100.0 / 32768.0,
			)
			if mf > 0 && ms * 2 < mf {
				inaudible += 1
				fail = true
			}
			if !covered {
				fmt.println("[ar-probe]   no decoder covered the playhead -> NOT SCHEDULED")
			}
			if !covered || peak < INAUDIBLE_PEAK_FS {
				inaudible += 1
				fail = true
			}
		}
	}
	if total == 0 {
		fmt.println("[ar-probe] FAIL: project has no audio clips")
		os.exit(3)
	}
	fmt.printf("[ar-probe] %d audio clips, %d inaudible, at %v fps\n", total, inaudible, fps)
	ar_finish(&fail, fps, len(parts) >= 3 ? parts[2] : "")
}

// audio_rate_fixture_run builds the project the defect needs, then runs the
// same checks against it plus a NEGATIVE CONTROL that reproduces the original
// bug. The control is what makes this a regression test rather than a snapshot:
// it proves the fixture really does go silent when the offset is unpinned, so a
// future revert cannot pass.
audio_rate_fixture_run :: proc(v: string) {
	parts := strings.split(v, "|")
	if len(parts) < 1 || parts[0] == "" {
		fmt.println("[ar-probe] need VYPER_AUDIO_RATE_FIXTURE=\"<scratch.wav>|<out.mp4>\"")
		os.exit(2)
	}
	wav := parts[0]
	out_path := len(parts) >= 2 ? parts[1] : ""

	// Author the project at 12fps, exactly the reported flow: a project created
	// at 12 whose clips were placed against that clock.
	project.frame_rate = AR_FIXTURE_RATE
	if !ar_write_fixture_wav(wav) {
		os.exit(3)
	}

	editor_flags.async_import_mode = false
	path_buf: [1024]u8
	n := 0
	for n < len(wav) && n < len(path_buf) - 1 {
		path_buf[n] = u8(wav[n])
		n += 1
	}
	path_buf[n] = 0
	import_media(cstring(&path_buf[0]))

	ac: ^Clip
	for ti in 0 ..< len(timeline.tracks) {
		for ci in 0 ..< len(timeline.tracks[ti].clips) {
			if timeline.tracks[ti].clips[ci].kind == .Audio {
				ac = &timeline.tracks[ti].clips[ci]
				break
			}
		}
		if ac != nil {
			break
		}
	}
	if ac == nil {
		fmt.println("[ar-probe] FAIL: fixture import produced no audio clip")
		os.exit(3)
	}
	as := find_asset(ac.asset_id)
	if as == nil {
		fmt.println("[ar-probe] FAIL: fixture audio clip has no asset")
		os.exit(3)
	}
	if ac.audio_src_rate <= 0 {
		fmt.println("[ar-probe] FAIL: import did not pin audio_src_rate")
		os.exit(3)
	}
	if AR_FIXTURE_SRC_START + AR_FIXTURE_SRC_LEN > as.audio_frames {
		fmt.printf(
			"[ar-probe] FAIL: fixture wants source [%d,%d) but the asset only has %d frames\n",
			AR_FIXTURE_SRC_START,
			AR_FIXTURE_SRC_START + AR_FIXTURE_SRC_LEN,
			as.audio_frames,
		)
		os.exit(3)
	}
	ac.source_start_frame = AR_FIXTURE_SRC_START
	ac.source_length_frames = AR_FIXTURE_SRC_LEN
	ac.timeline_start_frame = 0

	want := f64(AR_FIXTURE_SRC_START) / AR_FIXTURE_RATE
	fmt.printf(
		"[ar-probe] fixture: %d frames at %v fps = %.3fs into the file (tone starts at %.1fs); asset has %d frames, pin=%v\n",
		AR_FIXTURE_SRC_START,
		AR_FIXTURE_RATE,
		want,
		AR_FIXTURE_SILENT_S,
		as.audio_frames,
		ac.audio_src_rate,
	)

	// The user's action.
	project.frame_rate = AR_FIXTURE_NEW_RATE
	fps := timeline_fps()
	fmt.printf("[ar-probe] set project fps %v -> %v (timeline_fps=%v)\n", AR_FIXTURE_RATE, AR_FIXTURE_NEW_RATE, fps)

	fail := false
	audio_rpt.trace = true

	// 1. The pin survives the rate change.
	if !ar_report_rate_invariance(ac, want) {
		fail = true
	}
	// 2. The clip still plays the tone.
	mid := ac.timeline_start_frame + ac.source_length_frames / 2
	peak, got, covered := ar_measure_peak(mid)
	fmt.printf(
		"[ar-probe] pinned: frame %d peak=%d (%.1f%% FS) samples=%d covered=%t -> %s\n",
		mid,
		peak,
		f64(peak) * 100.0 / 32768.0,
		got,
		covered,
		peak >= INAUDIBLE_PEAK_FS ? "AUDIBLE" : "IN-AUDIBLE",
	)
	if !covered || peak < INAUDIBLE_PEAK_FS {
		fmt.println("[ar-probe] FAIL: pinned clip is not audible after the rate change")
		fail = true
	}

	// 3. The REAL preview mix path, frame by frame, at the new rate. The
	// measurements above decode straight from the anchor; this walks the same
	// audio_mix_frame the playback thread calls, so it also covers pacing, the
	// producer's demand calculation and the mixer.
	audio_provision(mid)
	mf, ms, mp := ar_simulate_preview_mix(ac.timeline_start_frame, ac.timeline_start_frame + ac.source_length_frames)
	fmt.printf(
		"[ar-probe] preview mix at %v fps: %d/%d frames carried signal, peak=%d (%.1f%% FS)\n",
		fps,
		ms,
		mf,
		mp,
		f64(mp) * 100.0 / 32768.0,
	)
	if mf > 0 && ms*2 < mf {
		fmt.println("[ar-probe] FAIL: preview mix delivered mostly silence")
		fail = true
	}

	// 4. NEGATIVE CONTROL: unpin it and the clip must go silent. This is the
	// original defect, reproduced on purpose -- if it stayed audible the fixture
	// would no longer discriminate and the checks above would be worthless.
	saved := ac.audio_src_rate
	ac.audio_src_rate = 0
	bad_peak, bad_got, bad_cov := ar_measure_peak(mid)
	ac.audio_src_rate = saved
	fmt.printf(
		"[ar-probe] control (unpinned): peak=%d samples=%d covered=%t -> %s\n",
		bad_peak,
		bad_got,
		bad_cov,
		bad_peak >= INAUDIBLE_PEAK_FS ? "AUDIBLE (fixture no longer discriminates!)" : "IN-AUDIBLE (bug reproduced)",
	)
	if bad_peak >= INAUDIBLE_PEAK_FS {
		fmt.println("[ar-probe] FAIL: fixture does not discriminate; the silent head is not silent")
		fail = true
	}

	// Leave the document in the pinned state for the export below.
	audio_provision(ac.timeline_start_frame)
	ar_finish(&fail, fps, out_path)
}

ar_finish :: proc(fail: ^bool, fps: f64, out_path: string) {
	if out_path != "" {
		rc := parity_probe_export(out_path)
		fmt.printf(
			"[ar-probe] export rc=%d nframes=%d duration=%.3fs\n",
			rc,
			render_job.nframes,
			f64(render_job.nframes) / fps,
		)
		if rc != 0 {
			fail^ = true
		}
	}
	if fail^ {
		fmt.println("[ar-probe] RESULT: FAIL")
		os.exit(1)
	}
	fmt.println("[ar-probe] RESULT: PASS")
	os.exit(0)
}

// ar_write_fixture_wav writes a 48kHz stereo s16 WAV that is digital silence
// for AR_FIXTURE_SILENT_S and a loud tone after it, so "read the wrong part of
// the file" is unmistakably audible.
ar_write_fixture_wav :: proc(path: string) -> bool {
	rate := 48000
	n := i64(AR_FIXTURE_SECONDS * f64(rate))
	data_bytes := n * 4 // stereo s16
	total := 44 + data_bytes
	buf: [dynamic]u8
	reserve(&buf, total)
	// RIFF / WAVE / fmt (PCM) / data, little-endian.
	ar_put_magic(&buf, "RIFF")
	ar_put_u32(&buf, u32(total - 8))
	ar_put_magic(&buf, "WAVE")
	ar_put_magic(&buf, "fmt ")
	ar_put_u32(&buf, 16) // PCM fmt chunk with no extension: exactly the 16 bytes below
	ar_put_u16(&buf, 1) // PCM
	ar_put_u16(&buf, 2) // stereo
	ar_put_u32(&buf, u32(rate))
	ar_put_u32(&buf, u32(rate * 4)) // byte rate
	ar_put_u16(&buf, 4) // block align
	ar_put_u16(&buf, 16) // bits per sample
	ar_put_magic(&buf, "data")
	ar_put_u32(&buf, u32(data_bytes))
	for i in 0 ..< n {
		t := f64(i) / f64(rate)
		v: i16 = 0
		if t >= AR_FIXTURE_SILENT_S {
			v = i16(math.sin(2.0 * math.PI * AR_FIXTURE_TONE_HZ * t) * 20000.0)
		}
		ar_put_u16(&buf, u16(v))
		ar_put_u16(&buf, u16(v))
	}
	defer delete(buf)
	// string IS []u8 in Odin, so the buffer is passed as-is.
	if err := os.write_entire_file(path, buf[:]); err != nil {
		fmt.println("[ar-probe] FAIL: write fixture wav:", err)
		return false
	}
	return true
}

// ar_put_magic appends a 4-character chunk id.
ar_put_magic :: proc(b: ^[dynamic]u8, m: string) {
	assert(len(m) == 4)
	for i in 0 ..< 4 {
		append(b, m[i])
	}
}

ar_put_u16 :: proc(b: ^[dynamic]u8, v: u16) {
	append(b, u8(v))
	append(b, u8(v >> 8))
}

ar_put_u32 :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v))
	append(b, u8(v >> 8))
	append(b, u8(v >> 16))
	append(b, u8(v >> 24))
}
