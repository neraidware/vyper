package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

	// Per-frame PREVIEW buffer lives in BSS, not on the probe's stack (match
	// render.odin / hw_probe.odin).
	probe_rate_buf: [PREVIEW_W * PREVIEW_H * 4]u8

	// VYPER_RATE_PROBE="<file>|<max_frames>": original-rate viability probe.
	//
	// S5 decodes the ORIGINAL (not the proxy) into the preview during forward
	// playback whenever a hw-backed decoder can sustain source fps. This probe
	// decodes `max_frames` frames STRAIGHT-FORWARD through a fresh hw decoder
	// (the exact forward-play path -- no seeks, exactly what a playing clip does)
	// and compares total decode+scale wall time against the source's own duration.
	//
	// Acceptance (the S5 deadline): the decode+scale pass must finish in LESS THAN
	// HALF the source duration. The preview's decode+scale is single-threaded, so
	// that means it occupies at most half of one core on average -- a full core of
	// CPU air is left for the render loop, audio, and UI on even a 2-core machine.
	// A clip that stands still at (say) 30fps for D ms uses at most one CPU core
	// when decode_ms < D; leaving one CORE of air means decode_ms < D/2.
	//
	// On a hw-less host the same run decodes in software and typically FAILS the
	// deadline for 1080p -- which is exactly the fallback the S5 gate relies on
	// (sw decode keeps the proxy).
	preview_rate_probe_run :: proc(v: string) {
		os.exit(rate_probe_pass(v))
	}

	rate_probe_pass :: proc(v: string) -> int {
		parts := strings.split(v, "|")
		if len(parts) < 2 {
			fmt.println("rate-probe: need VYPER_RATE_PROBE=\"<file>|<max_frames>\"")
			os.exit(2)
		}
		file := parts[0]
		max_frames, okf := strconv.parse_i64(parts[1])
		if !okf || max_frames <= 0 {
			fmt.println("rate-probe: bad \"<file>|<max_frames>\"")
			os.exit(2)
		}
		inp: [4096]u8
		n := 0
		for n < len(file) && n < len(inp) - 1 {
			inp[n] = u8(file[n])
			n += 1
		}
		inp[n] = 0
		path := cstring(&inp[0])

		// BSS, not stack: the 1.3MB preview buffer kept out of the probe's frame.
		dec: Clip_Decoder
		defer clip_decoder_reset(&dec)

		decoded: i64
		t0 := time.now()
		for f in i64(0) ..< max_frames {
			if !decode_clip_frame_sync(&dec, path, f, probe_rate_buf[:]) {
				break
			}
			decoded += 1
		}
		decode_ms := f64(time.duration_milliseconds(time.since(t0)))

		fps := 0.0
		if decoded > 0 && dec.fps_num > 0 && dec.fps_den > 0 {
			fps = f64(dec.fps_num) / f64(dec.fps_den)
		}
		duration_ms := fps > 0 ? f64(decoded) / fps * 1000.0 : 0

		// Decode+scale across the whole pass occupies decode_ms of ONE core; the
		// deadline is that it must stay under half the source duration so the
		// machine has a CPU core of air to spare.
		pass := decoded > 0 && decode_ms < duration_ms / 2.0
		util_pct := duration_ms > 0 ? decode_ms / duration_ms * 100.0 : 100.0
		fmt.printf(
			"[rate-probe] file=%s frames=%d fps=%.2f duration_ms=%.0f decode_ms=%.0f cpu_util=%.1f%%\n",
			file, decoded, fps, duration_ms, decode_ms, util_pct,
		)
		fmt.printf(
			"[rate-probe] %s (%.2f ms/frame vs %.1f ms frame budget)\n",
			pass ? "PASS: one CPU core of air left" : "FAIL: decode cannot sustain source fps",
			decoded > 0 ? decode_ms / f64(decoded) : 0,
			fps > 0 ? 1000.0 / fps : 0,
		)
		return pass ? 0 : 1
	}
}
