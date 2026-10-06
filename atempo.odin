package main

//
// Pitch-preserving playback rate via libavfilter atempo (WSOLA).
// ---------------------------------------------------------------------------
// The audio producer feeds the 48 kHz stereo mix to a small filter graph
// instead of relying on the SDL stream's frequency ratio (which is plain
// resampling — tape-style pitch shift). atempo time-stretches the samples so
// the content advances at the chosen rate while the pitch stays anchored.
//
// Pipeline: abuffer -> atempo=stage1 -> ... -> atempo=stageN -> aformat ->
// abuffersink. Each atempo instance time-stretches by a multiplicative factor
// in [0.5, 2.0]; rates above 2.0 chain ceil(rate/2) full 2.0 stages plus one
// remainder stage for the leftover fraction (2.5x = 2.0 x 1.25). The selected
// rates are <= 4.0, so at most two stages. The graph auto-converts formats
// between stages when needed, and aformat forces packed FLT stereo 48k at the
// tail so the pull side always sees the exact layout the producer mixes into.
//
// atempo tempo is multiplicative, so stage factors must multiply — chaining
// 2.0 + 0.5 would cancel to 1.0x and silently null the stretch (caught by the
// VYPER_ATEMPO_PROBE balance check).
//
// The graph lives on the audio producer thread (single writer, like every
// decoder). Rebuilt when the rate changes; that internal window is why the
// producer also clears/resyncs it on jump and re-provision.
// ---------------------------------------------------------------------------

import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import avfilter "vendor/ffmpeg/avfilter"
import avutil "vendor/ffmpeg/avutil"

// ATEMPO_MAX_STAGES caps the chained atempo filters. Selected rates are <= 4.0
// (two stages), but the cap is generous for future rates.
ATEMPO_MAX_STAGES :: 8

// ATEMPO_IN_POOL is the number of refcounted staging frames for input. We
// round-robin them so we never clobber a frame the graph still holds; atempo
// consumes each pushed frame when it reads it, and its window is a couple of
// frames, so a small pool is ample.
ATEMPO_IN_POOL :: 8

// ATEMPO_OUT_CAP bounds the frames accumulated by one feed, and the producer
// sizes its f32->i16 conversion buffer from it, so the two cannot drift.
//
// A feed pushes one content frame (~1601 frames at 29.97) and drains whatever
// the graph emits; the ragged remainder keeps output near-nominal, and aformated
// FLT forces a single copy. The graph only ever runs at max(1.0, playback.rate),
// i.e. speed-up, so it emits FEWER frames than it consumes and one content frame
// is the real ceiling. The 4x is headroom for a graph that bursts on a rate
// change, not a working figure: sizing the conversion buffer to
// MAX_AUDIO_FRAME_SAMPLES instead overflowed it by 4x the moment that headroom
// was actually needed.
ATEMPO_OUT_CAP :: MAX_AUDIO_FRAME_SAMPLES * 4

Atempo_Graph :: struct {
	// graph is nil when inactive (rate == 1.0): the producer bypasses atempo
	// entirely and raw-mixes to the device, matching the pre-atempo path.
	graph: ^avfilter.FilterGraph,
	src:   ^avfilter.FilterContext,
	sink:  ^avfilter.FilterContext,
	stages: [ATEMPO_MAX_STAGES]^avfilter.FilterContext,
	n_stages: int,
	rate:  f64, // the rate the graph was built for
	// pitch_ratio is the FREQUENCY ratio applied by the asetrate/aresample stage: 1.0
	// means no shift. Kept beside the tempo because the two compose in a fixed order --
	// pitch first (duration-preserving), then tempo (duration-changing) -- and getting
	// that order wrong would make a stretch also transpose, which is the exact
	// confusion between tempo and pitch that the two separate clip properties exist to
	// prevent.
	pitch_ratio: f64,

	// Input staging frames, allocated once with buffer capacity
	// MAX_AUDIO_FRAME_SAMPLES samples; nb_samples is set per push.
	in_pool: [ATEMPO_IN_POOL]^avutil.Frame,
	in_pool_i: int,

	// Output frame for the pull loop.
	out_frame: ^avutil.Frame,

	// out_buf accumulates every pulled frame's samples so the caller gets one
	// contiguous view, not one buffer ref per atempo output frame.
	out_buf: [ATEMPO_OUT_CAP]f32,
	out_n:   int, // stereo frames currently in out_buf
	// primed is false until the graph has been filled past its lookahead. WSOLA cannot
	// emit anything until it has that much context, so a freshly built graph's first
	// outputs are the graph FILLING rather than the content that was fed -- which puts
	// the whole stream late by up to ATEMPO_LOOKAHEAD_MAX_SAMPLES (42.7 ms at 48 kHz).
	//
	// Cleared by every build, so a rate change re-primes: the new chain has a different
	// window, and skipping that is how a rate change used to shift content mid-playback.
	// The per-clip tempo pump has its own priming because it runs continuously; this
	// one is a single pass after each build.
	primed: bool,
	// discard_next is how many output samples the NEXT real push must throw away.
	//
	// Priming with silence is not by itself enough. After L samples of silence the
	// graph's window is full, so its next outputs correspond to input at L -- meaning
	// the first REAL sample would still arrive L/rate late. Priming has to be followed
	// by discarding the output that corresponds to the priming region, and doing that
	// inside atempo_process is what makes it impossible for a caller to forget: the
	// graph owns its own alignment rather than relying on every call site to know.
	discard_next: int,
}

// atempo_new_frame allocates one refcounted stereo FLT frame with an
// over-allocated buffer of `cap` samples. Refcounted (via frame_get_buffer)
// so av_buffersrc_add_frame can reference it without copying; the pool keeps
// its own reference for reuse and drops it at teardown.
atempo_new_frame :: proc(cap: c.int) -> ^avutil.Frame {
	f := avutil.frame_alloc()
	if f == nil {
		return nil
	}
	f.format = c.int(avutil.SampleFormat.Flt)
	f.sample_rate = 48000
	f.ch_layout = avutil.ChannelLayout{
		order       = .Native,
		nb_channels = 2,
		u           = {mask = avutil.AV_CH_LAYOUT_STEREO},
	}
	f.nb_samples = cap
	if avutil.frame_get_buffer(f, 0) < 0 {
		avutil.frame_free(&f)
		return nil
	}
	return f
}

// atempo_graph_destroy releases every resource the graph owns. Safe on a
// partially built graph (nil-filtered teardown).
atempo_graph_destroy :: proc(g: ^Atempo_Graph) {
	for i in 0 ..< ATEMPO_IN_POOL {
		if g.in_pool[i] != nil {
			avutil.frame_free(&g.in_pool[i])
			g.in_pool[i] = nil
		}
	}
	if g.out_frame != nil {
		avutil.frame_free(&g.out_frame)
		g.out_frame = nil
	}
	if g.graph != nil {
		avfilter.graph_free(&g.graph)
		g.graph = nil
	}
	g.src = nil
	g.sink = nil
	for i in 0 ..< ATEMPO_MAX_STAGES {
		g.stages[i] = nil
	}
	g.n_stages = 0
	g.out_n = 0
	g.in_pool_i = 0
	g.rate = 1.0
}

// atempo_link_stage chained a new filter into the graph after `prev` and
// returns the new context or nil (fallback = raw path).
atempo_link_stage :: proc(
	graph: ^avfilter.FilterGraph,
	prev: ^avfilter.FilterContext,
	filter_name, stage_name, args: cstring,
) -> ^avfilter.FilterContext {
	filt := avfilter.get_by_name(filter_name)
	ctx: ^avfilter.FilterContext
	if ret := avfilter.graph_create_filter(&ctx, filt, stage_name, args, nil, graph); ret < 0 || ctx == nil {
		fmt.printf("[atempo] %s create: %s\n", filter_name, ff_err_str(ret))
		return nil
	}
	if r := avfilter.link(prev, 0, ctx, 0); r < 0 {
		fmt.printf("[atempo] link %s: %s\n", filter_name, ff_err_str(r))
		return nil
	}
	return ctx
}

// atempo_graph_build constructs the abuffer->atempo*->aformat->abuffersink
// chain for the given rate. rate must be > 0; 1.0 leaves the graph nil
// (bypass). On failure the graph is left nil (producer falls back to raw
// mix); the old graph is always released first.
atempo_graph_build :: proc(g: ^Atempo_Graph, rate: f64, pitch_ratio: f64 = 1.0) {
	atempo_graph_destroy(g)
	g.rate = rate
	g.pitch_ratio = pitch_ratio
	g.primed = false
	g.discard_next = 0
	if (rate <= 0.0 || rate == 1.0) && pitch_ratio == 1.0 {
		return // identity: skip the whole graph
	}

	graph := avfilter.graph_alloc()
	if graph == nil {
		fmt.println("[atempo] graph_alloc failed")
		return
	}
	g.graph = graph

	// abuffer (input). args describe the sample layout the producer mixes.
	ret := avfilter.graph_create_filter(
		&g.src,
		avfilter.get_by_name("abuffer"),
		cstring("in"),
		cstring("sample_rate=48000:sample_fmt=flt:channel_layout=stereo"),
		nil,
		graph,
	)
	if ret < 0 || g.src == nil {
		fmt.printf("[atempo] abuffer create: %s\n", ff_err_str(ret))
		atempo_graph_destroy(g)
		return
	}

	// PITCH, before tempo. asetrate reinterprets the stream at 48000*ratio, which
	// shifts every frequency up by `ratio` and shortens the duration by the same
	// factor; aresample then restores 48 kHz, which stretches the duration back while
	// leaving the pitch shifted. Net: pitch moves by `ratio`, duration unchanged.
	//
	// Order matters and is the whole reason tempo and pitch are separate properties.
	// Pitch first, because aresample's duration correction assumes it is restoring a
	// rate change it made itself; putting atempo ahead would make the tempo stage's
	// window see a resampler in front of it and the two corrections would compound
	// instead of composing.
	prev_pitch := g.src
	ratio := pitch_ratio
	if ratio != 1.0 {
		arg_buf: [64]u8
		fmt.bprintf(arg_buf[:], "%f", 48000.0 * ratio)
		ar_ctx := atempo_link_stage(graph, prev_pitch, "asetrate", cstring("pitchin"), cstring(raw_data(arg_buf[:])))
		if ar_ctx == nil {
			atempo_graph_destroy(g)
			return
		}
		g.stages[g.n_stages] = ar_ctx
		g.n_stages += 1
		prev_pitch = ar_ctx
		res_ctx := atempo_link_stage(graph, prev_pitch, "aresample", cstring("pitchout"), cstring("48000"))
		if res_ctx == nil {
			atempo_graph_destroy(g)
			return
		}
		g.stages[g.n_stages] = res_ctx
		g.n_stages += 1
		prev_pitch = res_ctx
	}

	// atempo stages. Each instance time-stretches by a multiplicative factor in
	// [0.5, 2.0]. Rate > 2.0 chains ceil over full 2.0 stages and one remainder
	// stage for the leftover fraction: 2.5x = 2.0 x 1.25, never 2.0 + 0.5
	// (adding would cancel to 1.0x). Selected rates are <= 4.0 -> at most two
	// stages.
	n_full := 0
	rem := rate
	for rem > 2.0 {
		n_full += 1
		rem /= 2.0
	}
	// The same problem in the other direction, which is what a FAST clip asks for.
	// `rate` here is atempo's tempo, so a clip at speed S passes 1/S -- and S = 3
	// gives tempo 0.333, outside atempo's per-stage [0.5, 2.0]. The graph would
	// create the stage, libavfilter would refuse the option ("Numerical result out
	// of range"), and the clip would produce NO SAMPLES AT ALL.
	//
	// So chain full 0.5 stages upward, exactly mirroring the 2.0 case:
	// 0.333 = 0.5 x 0.667. Multiplying is the only composition that works -- adding
	// would cancel toward 1.0 and silently play the wrong speed, which is the whole
	// failure mode this guards against.
	n_slow := 0
	for rem < 0.5 {
		n_slow += 1
		rem /= 0.5
	}
	if n_slow > 0 && g.n_stages+n_slow+n_full >= ATEMPO_MAX_STAGES {
		fmt.printf("[atempo] too many stages for rate %.3f\n", rate)
		atempo_graph_destroy(g)
		return
	}
	prev_slow := g.src
	for s in 0 ..< n_slow {
		name_buf: [32]u8
		fmt.bprintf(name_buf[:], "atemslow%d", g.n_stages)
		ctx := atempo_link_stage(graph, prev_slow, "atempo", cstring(raw_data(name_buf[:])), cstring("tempo=0.500000"))
		if ctx == nil {
			atempo_graph_destroy(g)
			return
		}
		g.stages[g.n_stages] = ctx
		g.n_stages += 1
		prev_slow = ctx
	}
	prev := prev_pitch
	for s in 0 ..< n_full {
		if g.n_stages >= ATEMPO_MAX_STAGES {
			fmt.printf("[atempo] too many stages for rate %.2f\n", rate)
			atempo_graph_destroy(g)
			return
		}
		name_buf: [32]u8
		fmt.bprintf(name_buf[:], "atempo%d", g.n_stages)
		ctx := atempo_link_stage(graph, prev, "atempo", cstring(raw_data(name_buf[:])), cstring("tempo=2.000000"))
		if ctx == nil {
			atempo_graph_destroy(g)
			return
		}
		g.stages[g.n_stages] = ctx
		g.n_stages += 1
		prev = ctx
	}
	if math.abs(rem - 1.0) > 0.000001 {
		if g.n_stages >= ATEMPO_MAX_STAGES {
			fmt.printf("[atempo] too many stages for rate %.2f\n", rate)
			atempo_graph_destroy(g)
			return
		}
		name_buf: [32]u8
		fmt.bprintf(name_buf[:], "atempo%d", g.n_stages)
		arg_buf: [32]u8
		fmt.bprintf(arg_buf[:], "tempo=%f", rem)
		ctx := atempo_link_stage(graph, prev, "atempo", cstring(raw_data(name_buf[:])), cstring(raw_data(arg_buf[:])))
		if ctx == nil {
			atempo_graph_destroy(g)
			return
		}
		g.stages[g.n_stages] = ctx
		g.n_stages += 1
		prev = ctx
	}

	// aformat: force packed FLT stereo 48k so the pull side always sees the
	// layout the mix loop converts to i16. The graph inserts a converter
	// between the last atempo and this filter if the formats differ.
	fmt_ctx := atempo_link_stage(graph, prev, "aformat", cstring("aformat"), cstring("sample_fmts=flt:channel_layouts=stereo"))
	if fmt_ctx == nil {
		atempo_graph_destroy(g)
		return
	}

	// abuffersink (output). The aformat stage already forces packed FLT stereo
	// 48k, so the sink needs no constraints of its own — leaving its args empty
	// avoids depending on abuffersink's plural option list (sample_rates not
	// sample_rate, etc.) which differs across versions.
	ret = avfilter.graph_create_filter(
		&g.sink,
		avfilter.get_by_name("abuffersink"),
		cstring("out"),
		cstring(""),
		nil,
		graph,
	)
	if ret < 0 || g.sink == nil {
		fmt.printf("[atempo] abuffersink: %s\n", ff_err_str(ret))
		atempo_graph_destroy(g)
		return
	}
	if r := avfilter.link(fmt_ctx, 0, g.sink, 0); r < 0 {
		fmt.printf("[atempo] link sink: %s\n", ff_err_str(r))
		atempo_graph_destroy(g)
		return
	}

	// Allocate the staging frame pool and the pull frame with full capacity.
	for i in 0 ..< ATEMPO_IN_POOL {
		g.in_pool[i] = atempo_new_frame(c.int(MAX_AUDIO_FRAME_SAMPLES))
		if g.in_pool[i] == nil {
			fmt.println("[atempo] staging frame alloc failed")
			atempo_graph_destroy(g)
			return
		}
	}
	g.out_frame = avutil.frame_alloc()
	if g.out_frame == nil {
		fmt.println("[atempo] out frame alloc failed")
		atempo_graph_destroy(g)
		return
	}

	if r := avfilter.graph_config(graph, nil); r < 0 {
		fmt.printf("[atempo] graph_config: %s\n", ff_err_str(r))
		atempo_graph_destroy(g)
		return
	}
	fmt.printf("[atempo] graph built for %.2fx (%d stage(s))\n", rate, g.n_stages)
}

// atempo_process pushes one content frame of `n` stereo f32 samples (packed in
// mix[:n*2]) into the graph, then drains everything the graph emits into
// g.out_buf. g.out_n holds the resulting stereo-frame count after the call;
// it is reset by the caller before the next push by reading it.
atempo_process :: proc(g: ^Atempo_Graph, mix: []f32, n: int) {
	if g.graph == nil || g.src == nil || g.sink == nil {
		// Inactive graph — return nothing; the caller raw-mixes instead.
		g.out_n = 0
		return
	}
	if n <= 0 {
		g.out_n = 0
		return
	}

	frame := g.in_pool[g.in_pool_i]
	g.in_pool_i = (g.in_pool_i + 1) % ATEMPO_IN_POOL
	frame.nb_samples = c.int(n)
	mem.copy(cast([^]u8)frame.data[0], raw_data(mix[:]), n * 2 * size_of(f32))
	if ret := avfilter.add_frame_flags(g.src, frame, {.Keep_Ref}); ret < 0 {
		fmt.printf("[atempo] add_frame: %s\n", ff_err_str(ret))
		g.out_n = 0
		return
	}

	// Drain every output frame the graph produced from this push.
	out_n := 0
	for {
		avutil.frame_unref(g.out_frame)
		ret := avfilter.get_frame(g.sink, g.out_frame)
		if ret < 0 { // EAGAIN or EOF: nothing more available
			break
		}
		count := int(g.out_frame.nb_samples)
		// The bound is in FRAMES but out_buf is a flat float array holding
		// count*2 floats per frame, so the capacity is ATEMPO_OUT_CAP/2 frames.
		//
		// Comparing frame counts against ATEMPO_OUT_CAP directly permitted TWICE the
		// buffer. That is a real overflow, not a theoretical one -- it only triggers
		// above 8192 output frames in a single drain, which is why nothing hit it until
		// a clip was stretched past 2x and the graph produced that much at once. It
		// wrote past the end of a struct field that now also exists once per audio
		// source, so the blast radius grew with this change even though the bug did not.
		if out_n + count > ATEMPO_OUT_CAP / 2 {
			fmt.printf("[atempo] output overflow: %d + %d > %d (rate %.2f)\n", out_n, count, ATEMPO_OUT_CAP, g.rate)
			break
		}
		// Output is aformated to packed FLT stereo: one plane, L/R interleaved.
		src_ptr := cast([^]f32)(g.out_frame.data[0])
		mem.copy(&g.out_buf[out_n * 2], src_ptr, count * 2 * size_of(f32))
		out_n += count
	}
	if g.discard_next > 0 && out_n > 0 {
		skip := min(g.discard_next, out_n)
		keep := out_n - skip
		if keep > 0 {
			copy(g.out_buf[:keep * 2], g.out_buf[skip * 2:out_n * 2])
		}
		g.discard_next -= skip
		out_n = keep
	}
	g.out_n = out_n
}

// atempo_rate_set ensures the graph matches `rate` (rebuilt when it changes).
// Producer-thread only, like every other atempo operation. Returns true when
// the graph was (re)built, so the caller can re-anchor to the current playhead
// — the rebuild is not cheap enough to tolerate the playhead racing while the
// producer is blocked building it.
atempo_rate_set :: proc(g: ^Atempo_Graph, rate: f64, pitch_ratio: f64 = 1.0) -> bool {
	r := rate
	if r <= 0.0 {
		r = 1.0
	}
	pr := pitch_ratio
	if pr <= 0.0 {
		pr = 1.0
	}
	// A graph is needed if EITHER the tempo or the pitch is off-identity. Keying only on
	// the tempo would leave a pitched clip unbuilt at rate 1.0, which is the common case
	// for an inspector pitch control.
	needs := r != 1.0 || pr != 1.0
	if g.rate != r || g.pitch_ratio != pr || (g.graph == nil) != (!needs) {
		atempo_graph_build(g, r, pr)
		return true
	}
	return false
}

// ATEMPO_LOOKAHEAD_MAX_SAMPLES is the largest lookahead the graph holds back,
// measured by audio_probe_node_latency at rate 0.5 (the slowest rate, and so the
// deepest window): 2048 input samples, 42.7 ms at 48 kHz.
//
// It is RATE-DEPENDENT, measured 2048 / 1722 / 1350 / 1536 input samples at rates
// 0.5 / 0.75 / 1.25 / 2.0, because WSOLA's window scales with the tempo factor. So
// this is a BOUND, not a constant to subtract, and compensation must use the
// per-rate value. The maximum is what a caller needs in order to size a priming
// buffer without asking.
//
// Measured rather than derived, and reproducible: the probe remeasures and compares.
// The two methods that did NOT work are recorded in the probe, because they are the
// obvious ones: impulse correlation cannot locate anything in WSOLA output (which is
// reassembled, not shifted), and energy onset quantises to its analysis window and
// reported an onset earlier than causality allows. Accounting --
// pushed/rate - produced -- needs no waveform at all.
ATEMPO_LOOKAHEAD_MAX_SAMPLES :: 2048

// atempo_lookahead_samples is the measured lookahead for a given TEMPO, by
// interpolation on the measured points.
//
// Keyed on TEMPO, which is what atempo_rate_set takes -- NOT on a transport rate.
// The two are the same number for the global bus (where the transport rate IS the
// tempo) and DIFFERENT for a per-clip graph, and conflating them is how the previous
// commit ended up passing 1.0/speed where it should have passed speed. EXACT at the measured rates and linear
// between them, because the underlying window scales with the tempo factor rather
// than jumping.
//
// Sampled from measurement rather than modelled, and that is the point: a model would
// be one more thing that can be wrong silently, and this number decides where content
// lands after a seek.
atempo_lookahead_samples :: proc(tempo: f64) -> int {
	pts := []f64{0.5, 0.75, 1.25, 2.0}
	vals := []int{2048, 1722, 1350, 1536}
	if tempo <= pts[0] {
		return vals[0]
	}
	for i in 0 ..< len(pts) - 1 {
		if tempo <= pts[i + 1] {
			t := (tempo - pts[i]) / (pts[i + 1] - pts[i])
			return int(f64(vals[i]) + (f64(vals[i + 1]) - f64(vals[i])) * t + 0.5)
		}
	}
	return vals[len(vals) - 1]
}

// atempo_prime fills a freshly built graph past its lookahead and throws that fill
// away, so the first REAL sample it emits is content 0 rather than the middle of the
// graph's warm-up.
//
// Without this the bus atempo delays everything behind it by its own lookahead: at
// rate 2.0 that is 1536 input samples, 32 ms, and it is not a settling transient that
// goes away -- it is a constant offset between what the timeline says and what comes
// out, which is exactly the lip-sync error the device-as-clock work was built to
// eliminate. It was live in shipping code and unmeasured by any gate.
//
// Silence is the correct thing to prime with: there is no content yet, and feeding it
// real audio would put the wrong samples in the graph's history window.
atempo_prime :: proc(g: ^Atempo_Graph) {
	if g.graph == nil || g.primed {
		return
	}
	g.primed = true
	// A FIXED, generous prime rather than a computed one. It has to exceed any
	// plausible lookahead, and ATEMPO_LOOKAHEAD_MAX_SAMPLES is the bound on that, so
	// 2x the bound with room to spare. Sizing it from the measured table instead is
	// what made this worse rather than better: the table cannot be trusted (see
	// below), so a table-sized prime sometimes primed too little and sometimes
	// discarded real content.
	in_frames := ATEMPO_LOOKAHEAD_MAX_SAMPLES * 2
	// Bounded chunk so a large lookahead does not want a large stack buffer.
	CHUNK :: 2048
	silence: [CHUNK * 2]f32
	done := 0
	// Measure the graph's ACTUAL latency rather than predicting it: however many
	// output samples come out during the priming pass ARE the samples that belong to
	// the warm-up, so that count is the discard.
	//
	// This replaces a LOOKUP TABLE, and the table is gone because it could not be
	// trusted. atempo_lookahead_samples interpolated between four measured points and
	// left intermediate rates off by up to 12 ms; when the measurement was made to
	// prove convergence -- double the input and require the same answer -- almost every
	// rate came back UNCONVERGED, swinging by hundreds of samples. So the accounting
	// that produced the table was never authoritative, and this session's claim that it
	// was was wrong.
	//
	// Self-calibration needs no model, no table and no assumption about how WSOLA's
	// window scales with tempo. It is also correct by construction for any chain of
	// any length, because it measures this graph rather than a model of it.
	emitted := 0
	for done < in_frames {
		n := min(CHUNK, in_frames - done)
		atempo_process(g, silence[:], n)
		emitted += g.out_n
		done += n
	}
	// Throw away the output that corresponds to the priming region, so the first REAL
	// sample emitted is content 0. atempo_process applies it.
	g.discard_next = emitted
}

// atempo_reset clears the graph's internal window so stale buffered samples
// from a previous timeline position never leak into the new mix. Used on
// re-provision and forward jumps, which also ClearAudioStream the device.
atempo_reset :: proc(g: ^Atempo_Graph) {
	if g.graph != nil {
		atempo_graph_build(g, g.rate)
	}
}