package vyper

import "core:c"
import "core:fmt"
import "core:os"
import "core:math"
import "core:strconv"
import "core:strings"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

	// ---------------------------------------------------------------------------
	// VYPER_CACHE_PROBE="<file>|<step>|<back>|<count>": adversarial cache-desync
	// check on ONE persistent decoder.
	//
	// The lost-region bug at a flush (no-gap) boundary comes from decode_clip_frame_sync's
	// cache-hit path advancing last_frame past the physical decoder position, so a later
	// forward request decodes from the wrong spot but labels the frame with an index from
	// the future. This probe forces the exact sequence on a single persistent decoder and
	// compares every served buffer against ground truth (in-order forward decode).
	//
	// Sequence per iteration i:
	//   a) request  target = base + i*step            (seek far ahead, caches it)
	//   b) request  back   = base + i*step - back     (non-consecutive, not cached -> seek back)
	//      -- NOW cache holds `target` but the physical decoder is parked at `back`
	//   c) request  target again                      (CACHE HIT: old code sets last=target)
	//   d) request  target+1   (forward fast-path: old code decodes from physical `back+1`, labels target+1)
	// Ground truth for key k is the hash of the k-th in-order decoded frame.
	// ---------------------------------------------------------------------------
	cache_probe_run :: proc(v: string) {
		editor_flags.preview_proxy_enabled = false // ground truth vs the original decode path
		parts := strings.split(v, "|")
		if len(parts) < 4 {
			fmt.println("cache-probe: need VYPER_CACHE_PROBE=\"<file>|<step>|<back>|<count>\"")
			os.exit(2)
		}
		file := parts[0]
		step := i64(1)
		if sv, ok := strconv.parse_i64(parts[1]); ok {
			step = sv
		}
		back := i64(1)
		if sv, ok := strconv.parse_i64(parts[2]); ok {
			back = sv
		}
		count := i64(3)
		if sv, ok := strconv.parse_i64(parts[3]); ok {
			count = sv
		}

		buf: [4096]u8
		n := 0
		for n < len(file) && n < len(buf) - 1 {
			buf[n] = u8(file[n])
			n += 1
		}
		buf[n] = 0
		path := cstring(&buf[0])
		max_key := i64(0)
		for i in 0 ..< count {
			target := i64(48) + i * step
			if target + 4 > max_key {
				max_key = target + 4
			}
		}

		// Ground truth: in-order decode every frame 0..max_key, hash each.
		clear(&probe_hashes)
		seq: Clip_Decoder
		if !open_clip_decoder(&seq, path) {
			fmt.println("cache-probe: open (ground truth) failed")
			os.exit(2)
		}
		for fi in i64(0) ..= max_key {
			if !decode_source_frame(&seq, fi) {
				fmt.printf("cache-probe: ground-truth decode stopped at %d\n", fi)
				break
			}
			decode_into_buffer(&seq, probe_hash_buf[:], PREVIEW_W, PREVIEW_H)
			append(&probe_hashes, fnv64(probe_hash_buf[:]))
		}
		clip_decoder_reset(&seq)

		// Fresh persistent decoder exercising the cache path (decode_clip_frame_sync).
		pc: Clip_Decoder
		if !open_clip_decoder(&pc, path) {
			fmt.println("cache-probe: open (suspect) failed")
			os.exit(2)
		}
		bad := 0
		checked := 0
		for i := i64(0); i < count; i += 1 {
			target := i64(48) + i * step
			backf := target - back
			if backf < 0 {
				backf = 0
			}
			// a) far-ahead request (seek + cache).
			if !decode_clip_frame_sync(&pc, path, target, probe_hash_buf[:]) {
				fmt.printf("  iter %d: step-target %d decode failed\n", i, target)
				continue
			}
			// b) jump back (seek, not cached at first).
			if !decode_clip_frame_sync(&pc, path, backf, probe_hash_buf[:]) {
				fmt.printf("  iter %d: back %d decode failed\n", i, backf)
				continue
			}
			// c) re-request target (cache hit path — old code advanced last_frame here).
			if !decode_clip_frame_sync(&pc, path, target, probe_hash_buf[:]) {
				fmt.printf("  iter %d: cache-hit target %d decode failed\n", i, target)
				continue
			}
			// d) forward request target+1 — the desync surface.
			next := target + 1
			if int(next) >= len(probe_hashes) {
				break
			}
			checked += 1
			if !decode_clip_frame_sync(&pc, path, next, probe_hash_buf[:]) {
				fmt.printf("  iter %d: next %d decode failed\n", i, next)
				continue
			}
			got := fnv64(probe_hash_buf[:])
			want := probe_hashes[next]
			if got != want {
				bad += 1
				fmt.printf("  MISMATCH target=%d back=%d next=%d got=%016x want=%016x last=%d\n",
					target, backf, next, got, want, pc.last_frame)
			} else {
				fmt.printf("  ok       target=%d back=%d next=%d last=%d\n",
					target, backf, next, pc.last_frame)
			}
		}
		fmt.printf("[cache-probe] checked=%d mismatches=%d (step=%d back=%d count=%d)\n",
			checked, bad, step, back, count)
		clip_decoder_reset(&pc)
		os.exit(bad == 0 ? 0 : 1)
	}

	// decode_repeat_probe_run walks a clip the way CONFORM walks it: a project faster
	// than the source asks for the same source frame several times in a row.
	//
	//   VYPER_DECODE_REPEAT_PROBE="<file>|<project_fps>|<source_fps>"
	//
	// It asserts that serving a held frame does not re-seek. That is not observable
	// any other way: a seek back to the frame already decoded lands on the same
	// frame and leaves every other field identical, so "we stopped re-seeking" would
	// otherwise be a performance claim with nothing to test it — which is how the AV1
	// "Missing reference frame needed for show_existing_frame" failures survived,
	// since a repeated request flushed the decoder and the next unit wanted a
	// reference the flush had dropped.
	//
	// The failure mode is a DECODER FAILURE, not slowness: on AV1 the flush destroys
	// the reference frames, so the held request itself errors out.
	decode_repeat_probe_run :: proc(v: string) {
		editor_flags.preview_proxy_enabled = false
		parts := strings.split(v, "|")
		if len(parts) < 3 {
			fmt.println("decode-repeat-probe: need VYPER_DECODE_REPEAT_PROBE=\"<file>|<project_fps>|<source_fps>\"")
			os.exit(2)
		}
		buf: [4096]u8
		n := 0
		for n < len(parts[0]) && n < len(buf) - 1 {
			buf[n] = u8(parts[0][n])
			n += 1
		}
		buf[n] = 0
		path := cstring(&buf[0])
		proj_fps, pok := strconv.parse_f64(parts[1])
		src_fps, sok := strconv.parse_f64(parts[2])
		if !pok || !sok || proj_fps <= 0 || src_fps <= 0 {
			fmt.println("decode-repeat-probe: bad rates")
			os.exit(2)
		}
		hold := int(math.floor(proj_fps / src_fps + 0.5))
		if hold < 1 {
			hold = 1
		}

		dec: Clip_Decoder
		if !open_clip_decoder(&dec, path) {
			fmt.println("decode-repeat-probe: open failed")
			os.exit(2)
		}
		fails := 0
		// Walk 40 timeline frames. Source frames are demanded `hold` times each.
		WALK_FRAMES :: 40
		seen_src := -1
		seeks_before_hold := i64(-1)
		for f in 0 ..< WALK_FRAMES {
			// Conform: the source frame this timeline frame shows.
			want_src := int(math.floor(f64(f) * (src_fps / proj_fps) + 0.5))
			if !decode_source_frame(&dec, i64(want_src)) {
				fmt.printf("[decode-repeat-probe] FAIL decode of source frame %d (timeline %d) failed\n", want_src, f)
				fails += 1
				break
			}
			if want_src != seen_src {
				// First time we are asked for this source frame: record the seek
				// baseline so the repeats that follow can be measured against it.
				seen_src = want_src
				seeks_before_hold = dec.seek_count
			} else {
				// A repeat of the frame already decoded. It must not have re-seeked.
				if dec.seek_count != seeks_before_hold {
					fmt.printf(
						"[decode-repeat-probe] FAIL held frame %d (timeline %d) re-seeked: seek_count %d -> %d\n",
						want_src, f, seeks_before_hold, dec.seek_count,
					)
					fails += 1
					break
				}
			}
		}
		// A SCRUB walk, which is the path the forward walk above never reaches and the
		// one AV1 actually fails on. Backward jumps force seek_to_source_frame, which
		// calls avcodec_flush_buffers — and an AV1 stream that uses show_existing_frame
		// (a frame that is a copy of an earlier reference) cannot survive its references
		// being flushed. The symptom is "Missing reference frame needed for
		// show_existing_frame", and unlike the repeat case it does not come with a
		// visibly wrong picture: the decoder simply stops.
		//
		// So this asserts only that every frame the scrub asks for DECODES. A scrub that
		// works forwards and then poisons itself on the way back is the shape of the
		// reported failure, and nothing else in the suite seeks a conformed AV1 clip.
		source_frames: i64 = 0
		for probe_frame := i64(0); probe_frame < 4096; probe_frame += 1 {
			if !decode_source_frame(&dec, probe_frame) {
				break
			}
			source_frames = probe_frame + 1
		}
		if source_frames <= 1 {
			fmt.println("[decode-repeat-probe] FAIL could not walk the source to find its length")
			os.exit(2)
		}
		scrub_fails := 0
		// Targets are a FRACTION of the source, not absolute frame numbers. Hardcoded
		// indices were wrong the moment the probe ran against a shorter clip: a
		// 90-frame fixture was asked for frame 120, decode correctly refused it, and the
		// probe reported a decoder fault that was really a bad test.
		jumps := ([]f64{0.0, 0.7, 0.25, 0.95, 0.05, 0.5, 0.1})
		for frac in jumps {
			jump := i64(frac * f64(source_frames - 1))
			if jump < 0 {
				jump = 0
			}
			if !decode_source_frame(&dec, jump) {
				scrub_fails += 1
				fmt.printf(
					"[decode-repeat-probe] FAIL scrub to source frame %d of %d did not decode\n",
					jump, source_frames,
				)
			}
		}

		clip_decoder_reset(&dec)
		if scrub_fails > 0 {
			fmt.printf(
				"[decode-repeat-probe] FAIL %d scrub targets failed to decode — a forward-only walk passes, so this is the seek path\n",
				scrub_fails,
			)
			fails += scrub_fails
		}
		if fails == 0 {
			fmt.printf(
				"[decode-repeat-probe] OK: %d timeline frames at %gfps over a %gfps source (hold %d) served every held frame without re-seeking\n",
				WALK_FRAMES, proj_fps, src_fps, hold,
			)
		}
		os.exit(fails == 0 ? 0 : 1)
	}

}
