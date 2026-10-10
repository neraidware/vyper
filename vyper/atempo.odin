package vyper

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
// FFmpeg n9.0.2 permits atempo tempo [0.5, 100]. Single-stage execution is
// preferred for WSOLA accuracy; these bounds are only the decomposition fallback.
ATEMPO_CHAIN_MIN_TEMPO :: 0.5
ATEMPO_CHAIN_MAX_TEMPO :: 2.0

// ATEMPO_SCRUB_STAGES is how many atempo stages the SCRUB graph is built with.
// Two stages span 0.25x..4.0x with each stage inside [0.5, 2.0] at the extremes:
// 0.25x = 0.5 x 0.5, 4.0x = 2.0 x 2.0. Fixed, so a velocity change only rewrites
// the per-stage tempo instead of changing the chain's LENGTH.
ATEMPO_SCRUB_STAGES :: 2

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
	// Cumulative graph-domain sample frames since build. For the live transport,
	// input_total - output_total*rate is content still held inside WSOLA. The device
	// clock subtracts that holdback as well as output still queued at the device, so
	// dev_frame follows audible content rather than input already accepted by graph.
	input_total:  i64,
	output_total: i64,
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
	g.input_total = 0
	g.output_total = 0
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

	// Fallback decomposition into per-stage factors. Multiply stages, never add:
	// 2.5x = 2.0 x 1.25, not 2.0 + 0.5 (which cancels to 1.0x).
	n_full := 0
	rem := rate
	for rem > ATEMPO_CHAIN_MAX_TEMPO {
		n_full += 1
		rem /= ATEMPO_CHAIN_MAX_TEMPO
	}
	// The same decomposition in the other direction. `rate` is atempo's TEMPO and
	// atempo's tempo IS the speed multiplier: a clip at speed S passes tempo=S, not 1/S.
	//
	// For a tempo below the minimum, chain full 0.5 stages upward:
	// 4.0 = 0.5 x 0.5 x 2.0 x 2.0. Multiplying is the only composition that works -- adding
	// would cancel toward 1.0 and silently play the wrong speed, which is the whole
	// failure mode this guards against.
	n_slow := 0
	for rem < ATEMPO_CHAIN_MIN_TEMPO {
		n_slow += 1
		rem /= ATEMPO_CHAIN_MIN_TEMPO
	}
	if n_slow > 0 && g.n_stages+n_slow+n_full >= ATEMPO_MAX_STAGES {
		fmt.printf("[atempo] too many stages for rate %.3f\n", rate)
		atempo_graph_destroy(g)
		return
	}
	// From the PITCH chain, not from the source. The chain is
	//   src -> asetrate -> aresample -> atemslow* -> atempo(full)* -> atempo(rem) -> aformat
	// and every stage after aresample must hang off the one before it. Starting the
	// atempo stages back at g.src severs the chain: the slow stages are still built and
	// still counted, but nothing plays through them, so a clip asking for >2x runs at
	// the WRONG SPEED while every stage count and bound check looks correct.
	//
	// TRY ONE STAGE FIRST, before any chaining.
	//
	// The vendored 9.0.2 accepts a single stage up to tempo 100. For rates at/above
	// the documented minimum, try one stage and chain only if this build refuses it.
	// Below the minimum, decompose directly rather than asking libavfilter for a known
	// invalid tempo and printing an error on every graph rebuild.
	//
	// This is an ACCURACY fix, not just a compatibility one. Chaining compounds WSOLA's
	// per-stage segment rounding, and audio_probe_clip_tempo measures the damage:
	//
	//     speed 2.5 -> 0.39737 against a wanted 0.40000    0.66% short, 2 stages
	//     speed 4.0 -> 0.24800 against a wanted 0.25000    0.80% short, 2 stages
	//     speed 3.0 -> 0.33336 against a wanted 0.33333    0.01% short, 2 stages
	//
	// 0.8% is 4.8 s of drift across a 10-minute clip, which is audible and unacceptable
	// in an editor. One stage at 4.0 measures exact, so the chaining path survives only
	// as the fallback for a build that cannot take a single stage.
	if rate >= ATEMPO_CHAIN_MIN_TEMPO {
		rate_buf: [32]u8
		fmt.bprintf(rate_buf[:], "tempo=%f", rate)
		single := atempo_link_stage(graph, prev_pitch, "atempo", cstring("atempo0"), cstring(raw_data(rate_buf[:])))
		if single != nil {
			g.stages[g.n_stages] = single
			g.n_stages += 1
			atempo_finish(graph, g, single)
			return
		}
	}

	prev_slow := prev_pitch
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
	// From the slow stages, so a >2x clip actually runs through them.
	prev := prev_slow
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

	atempo_finish(graph, g, prev)
}

// atempo_graph_build_fixed constructs the SAME abuffer->atempo*->aformat->abuffersink
// chain as atempo_graph_build, but with a FIXED number of atempo stages each
// configured at the MAXIMUM tempo, ready to be retuned in place.
//
// The stages are built at tempo=ATEMPO_CHAIN_MAX_TEMPO rather than at the
// requested rate because atempo sizes its internal ring from the tempo present
// when the filter is CONFIGURED, and asserts `read_size <= ring` on every pull.
// A ring sized for the rate it was built at cannot absorb a later retune upward:
// the first fast scrub aborts the process inside libavfilter
// (af_atempo.c:445). A ring sized for the maximum makes every later retune read
// LESS than the ring holds, so the invariant holds across the whole range.
//
// stage_count stages each carrying rate^(1/stage_count) spans
// [MIN^(1/n), MAX^(1/n)] per stage, so every stage stays inside atempo's own
// [ATEMPO_CHAIN_MIN_TEMPO, ATEMPO_CHAIN_MAX_TEMPO] window.
atempo_graph_build_fixed :: proc(g: ^Atempo_Graph, stage_count: int) {
	atempo_graph_destroy(g)
	g.rate = 1.0
	g.pitch_ratio = 1.0
	// clamp into [1, ATEMPO_MAX_STAGES]; proc parameters are immutable in Odin.
	n := clamp(stage_count, 1, ATEMPO_MAX_STAGES)

	graph := avfilter.graph_alloc()
	if graph == nil {
		fmt.println("[atempo] graph_alloc failed")
		return
	}
	g.graph = graph

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

	prev := g.src
	for s in 0 ..< n {
		name_buf: [32]u8
		fmt.bprintf(name_buf[:], "atempo%d", s)
		// MAXIMUM tempo, not the requested one -- see the header.
		ctx := atempo_link_stage(
			graph,
			prev,
			"atempo",
			cstring(raw_data(name_buf[:])),
			cstring("tempo=2.000000"),
		)
		if ctx == nil {
			atempo_graph_destroy(g)
			return
		}
		g.stages[g.n_stages] = ctx
		g.n_stages += 1
		prev = ctx
	}
	atempo_finish(graph, g, prev)
}

// atempo_rate_set_inplace retunes an ALREADY-BUILT fixed graph by writing each
// stage's tempo, instead of destroying and rebuilding the whole filter chain.
//
// This is the difference between a scrub that stays smooth and one that tears
// the engine down on every velocity change. The rebuild path frees and
// reallocates the entire graph, forces audio_device_clear (dropping everything
// the device had not yet played) and re-anchors every decoder (discarding its
// fifo); at drag speed that is hundreds of rebuilds per gesture, and the heap
// churn underneath it is not safe to assume benign.
//
// Each stage takes the SAME factor, so a stage's tempo stays inside atempo's
// own window for every rate this supports.
atempo_rate_set_inplace :: proc(g: ^Atempo_Graph, rate: f64) -> bool {
	if g.graph == nil || g.n_stages <= 0 {
		return false
	}
	r := rate
	if r <= 0.0 {
		r = 1.0
	}
	// n stages each at r^(1/n) multiplies out to exactly r.
	factor := math.pow(r, 1.0 / f64(g.n_stages))
	if factor < ATEMPO_CHAIN_MIN_TEMPO {
		factor = ATEMPO_CHAIN_MIN_TEMPO
	}
	if factor > ATEMPO_CHAIN_MAX_TEMPO {
		factor = ATEMPO_CHAIN_MAX_TEMPO
	}
	for i in 0 ..< g.n_stages {
		// opt_set on the FilterContext reaches the atempo private context, which
		// is where the "tempo" option lives.
		avutil.opt_set_double(transmute(rawptr)g.stages[i].priv, cstring("tempo"), factor, 0)
	}
	g.rate = r
	return true
}

// atempo_finish wires the tail of the graph -- aformat, abuffersink, configure -- and
// configures it. Split out so the single-stage fast path and the chained fallback share
// one implementation; there is no reason for the two to differ past the last stage.
atempo_finish :: proc(graph: ^avfilter.FilterGraph, g: ^Atempo_Graph, prev: ^avfilter.FilterContext) {
	ret: i32
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
	fmt.printf("[atempo] graph built for %.2fx (%d stage(s))\n", g.rate, g.n_stages)
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
	g.input_total += i64(n)

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
	g.out_n = out_n
	g.output_total += i64(out_n)
}

// atempo_pending_input_samples returns content accepted by the graph but not yet
// represented in output. The device clock subtracts this algorithmic holdback along
// with output samples that the device has not consumed yet.
//
// atempo tempo `r` emits out/in = 1/r, therefore output_total*r input samples are
// represented. Their difference from input_total is the graph's current holdback,
// measured from actual cumulative counts rather than a rate lookup table.
atempo_pending_input_samples :: proc(g: ^Atempo_Graph) -> i64 {
	if g.graph == nil || g.rate <= 0 {
		return 0
	}
	pending := f64(g.input_total) - f64(g.output_total) * g.rate
	return max(0, i64(pending + 0.5))
}

// atempo_rate_set ensures the graph matches `rate` (rebuilt when it changes).
// Producer-thread only, like every other atempo operation. Returns true when
// the graph was (re)built, so the caller can re-anchor to the current playhead
// — the rebuild is not cheap enough to tolerate the playhead racing while the
// producer is blocked building it.

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

// atempo_reset clears the graph's internal window so stale buffered samples
// from a previous timeline position never leak into the new mix. Used on
// re-provision and forward jumps, which also ClearAudioStream the device.
atempo_reset :: proc(g: ^Atempo_Graph) {
	if g.graph != nil {
		atempo_graph_build(g, g.rate, g.pitch_ratio)
	}
}
