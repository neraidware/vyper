package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

// VYPER_ATEMPO_PROBE="<rate>[,rate,...]|ALL": pitch-preservation probe.
//
// Synthesizes a 440 Hz stereo tone at 48 kHz, routes it through the SAME
// atempo graph the audio producer uses, and checks two properties:
//
//  1. Pitch preserved: the output's zero-crossing frequency stays ~440 Hz at
//     every rate. The old SetAudioStreamFrequencyRatio path resampled, which
//     would shift the tone to 440*rate Hz (880 Hz at 2x) — that is the tape-
//     style pitch shift S6 replaces.
//  2. Balance: total output samples ~= total input / rate, so the stretched
//     stream advances R x faster than its source content (the wall-clock math
//     the producer relies on).
//
// Rates are given as a comma list, or "ALL" for every PLAYBACK_RATES entry.
// Exit 0 = all checks passed, 1 = any pitch/balance failure, 2 = usage.
// No SDL device is involved: this is the offline gate; the real-device soak is
// VYPER_AUTOPLAY + PCMDUMP under a running session.

ATEMPO_PROBE_SR :: 48000.0
ATEMPO_PROBE_TONE_HZ :: 440.0
ATEMPO_PROBE_CONTENT_SEC :: 8.0 // long enough for atempo's window + a stead-state region
ATEMPO_PROBE_AMP :: 0.5
// Probe input/output staging. Content at the slowest testable rate (0.5x would
// double it) — probe covers >1 rates so output <= input. Sized for 8 s of
// stereo f32, which also covers a 0.5x run if the rate list grows.
ATEMPO_PROBE_BUF_SEC :: 16
probe_atempo_mix:  [MAX_AUDIO_FRAME_SAMPLES * 2]f32
probe_atempo_out:  [ATEMPO_PROBE_BUF_SEC * ATEMPO_PROBE_SR * 2]f32

atempo_probe_run :: proc(v: string) {
	os.exit(atempo_probe_pass(v))
}

atempo_probe_pass :: proc(v: string) -> int {
	// One graph reused across rates, torn down between them (mirrors the live
	// producer rebuilding on rate change).
	g: Atempo_Graph
	defer atempo_graph_destroy(&g)

	n_rates := 0
	bad := 0
	if v == "ALL" {
		for r in PLAYBACK_RATES {
			n_rates += 1
			if !atempo_probe_check(&g, r) {
				bad += 1
			}
		}
	} else {
		parts := strings.split(v, ",")
		for part in parts {
			r, ok := strconv.parse_f64(strings.trim_space(part))
			if !ok || r <= 0.5 {
				fmt.printf("[atempo-probe] bad rate %q (want >0.5, got %v)\n", part, r)
				return 2
			}
			n_rates += 1
			if !atempo_probe_check(&g, r) {
				bad += 1
			}
		}
		delete(parts)
	}
	if n_rates == 0 {
		fmt.println("atempo-probe: need VYPER_ATEMPO_PROBE=\"<rate>[,rate,...]|ALL\"")
		return 2
	}
	fmt.printf("[atempo-probe] checked=%d failures=%d\n", n_rates, bad)
	return bad == 0 ? 0 : 1
}

// atempo_probe_check runs one rate through the graph and asserts pitch +
// balance. The graph is rebuilt for the rate; teardown happens at the caller's
// loop between rates (live-rate-swap behavior: rebuild over the same struct).
atempo_probe_check :: proc(g: ^Atempo_Graph, rate: f64) -> bool {
	// Rate 1.0 must bypass the graph entirely (producer raw-mixes).
	if rate == 1.0 {
		atempo_graph_build(g, rate)
		if g.graph != nil {
			fmt.printf("[atempo-probe] %.2f: graph must be nil (bypass path)\n", rate)
			return false
		}
		return true
	}
	atempo_graph_build(g, rate)
	if g.graph == nil {
		fmt.printf("[atempo-probe] %.2f: graph build failed\n", rate)
		return false
	}

	// Feed a 440 Hz, amp 0.5 stereo tone in producer-sized frame chunks. The
	// exact per-frame sample count doesn't matter to atempo — what matters is
	// that we hit the same add/drain path the live feed does. Note: the graph
	// has no EOF/flush side channel in this design, so a small tail (~one
	// atempo window, ~40 ms) stays buffered in the filter after the last push;
	// the balance tolerance below absorbs exactly that.
	total_in := int(ATEMPO_PROBE_CONTENT_SEC * ATEMPO_PROBE_SR)
	phase := 0.0
	out_n := 0
	dc := 2.0 * math.PI * ATEMPO_PROBE_TONE_HZ / ATEMPO_PROBE_SR
	for fed := 0; fed < total_in; fed += MAX_AUDIO_FRAME_SAMPLES {
		n := min(total_in - fed, MAX_AUDIO_FRAME_SAMPLES)
		for s in 0 ..< n {
			v := ATEMPO_PROBE_AMP * math.sin(phase)
			phase += dc
			probe_atempo_mix[s * 2 + 0] = f32(v)
			probe_atempo_mix[s * 2 + 1] = f32(v)
		}
		atempo_process(g, probe_atempo_mix[:], n)
		if out_n + g.out_n * 2 > len(probe_atempo_out) {
			fmt.printf("[atempo-probe] %.2f: output buffer overflow\n", rate)
			return false
		}
		mem.copy(&probe_atempo_out[out_n], &g.out_buf[0], g.out_n * 2 * size_of(f32))
		out_n += g.out_n * 2
	}

	// 1) Pitch via steady-region zero crossings. Start and end of the output
	// are atempo's transition/alignment frames — skip 1 s and the last 0.5 s.
	skip := int(1.0 * ATEMPO_PROBE_SR) * 2
	tail := int(0.5 * ATEMPO_PROBE_SR) * 2
	if out_n <= skip + tail + 1024 {
		fmt.printf("[atempo-probe] %.2f: too little output for pitch check (%d samples)\n", rate, out_n)
		return false
	}
	crossings := 0
	prev := probe_atempo_out[skip]
	for i := skip + 2; i < out_n - tail; i += 2 {
		cur := probe_atempo_out[i]
		if (prev < 0.0 && cur >= 0.0) || (prev > 0.0 && cur <= 0.0) {
			crossings += 1
		}
		prev = cur
	}
	region := f64(out_n - tail - skip) / 2.0 / ATEMPO_PROBE_SR // stereo frames -> seconds
	hz := f64(crossings) / (2.0 * region)
	// Tolerances: atempo's WSOLA alignment means the crossing count is exact
	// for a pure tone, but keep 2.5% headroom for the chosen steady window.
	pitch_ok := math.abs(hz - ATEMPO_PROBE_TONE_HZ) < ATEMPO_PROBE_TONE_HZ * 0.025

	// 2) Balance: out ~= in / rate. atempo's window holds a couple of frames
	// of input at the boundary; allow 3%.
	out_stereo := f64(out_n) / 2.0
	in_total := f64(total_in)
	want := in_total / rate
	bal_ok := math.abs(out_stereo - want) < want * 0.03
	if !(pitch_ok && bal_ok) {
		fmt.printf(
			"[atempo-probe] %.2f: pitch=%.1fHz%s balance=%.0f/%.0f%s (in=%d out=%.0f)\n",
			rate, hz, pitch_ok ? " ok" : " FAIL",
			out_stereo, want, bal_ok ? " ok" : " FAIL",
			total_in, out_stereo,
		)
	}
	return pitch_ok && bal_ok
}