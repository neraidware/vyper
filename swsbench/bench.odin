package swsbench

import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:time"
import avutil "../vendor/ffmpeg/avutil"
import sws "../vendor/ffmpeg/swscale"
import yuv "../vendor/yuv"

W :: 1920
H :: 1082
ITERS :: 60

bench :: proc(label: string, src_fmt: avutil.PixelFormat, dst_fmt: avutil.PixelFormat, src_bpp: int, flags: sws.Flags) {
	src := make([]u8, W * H * src_bpp); defer delete(src)
	dst := make([]u8, W * H * 4); defer delete(dst)
	for i in 0 ..< len(src) { src[i] = u8(i * 131 + i / 7) }
	ctx := sws.getContext(W, H, src_fmt, W, H, dst_fmt, flags, nil, nil, nil)
	if ctx == nil { fmt.printf("%-22s getContext failed\n", label); return }
	defer sws.freeContext(ctx)
	sf := avutil.frame_alloc()
	df := avutil.frame_alloc()
	defer { p := sf; avutil.frame_free(&p) }
	defer { p := df; avutil.frame_free(&p) }
	sf.format = c.int(src_fmt); sf.width = W; sf.height = H
	sd: [4][^]u8; sl: [4]c.int
	avutil.image_fill_arrays(&sd[0], &sl[0], raw_data(src), src_fmt, W, H, 32)
	for i in 0 ..< 4 { sf.data[i] = sd[i]; sf.linesize[i] = sl[i] }
	df.format = c.int(dst_fmt); df.width = W; df.height = H
	dd: [4][^]u8; dl: [4]c.int
	avutil.image_fill_arrays(&dd[0], &dl[0], raw_data(dst), dst_fmt, W, H, 32)
	for i in 0 ..< 4 { df.data[i] = dd[i]; df.linesize[i] = dl[i] }
	sws.scale_frame(ctx, df, sf)
	t0 := time.tick_now()
	for _ in 0 ..< ITERS { sws.scale_frame(ctx, df, sf) }
	fmt.printf("%-22s %.3f ms/frame\n", label, f64(time.tick_since(t0)) / 1e6 / ITERS)
}

main :: proc() {
	fmt.printf("%dx%d iters=%d\n", W, H, ITERS)
	bench("RGBA->NV12 bilinear", .RGBA, .NV12, 4, {.Bilinear})
	bench("RGBA->YUV420P bilinear", .RGBA, .YUV420P, 4, {.Bilinear})
	bench("RGB24->YUV420P bilinear", .RGB24, .YUV420P, 3, {.Bilinear})
	bench("RGB24->NV12 bilinear", .RGB24, .NV12, 3, {.Bilinear})
	bench("BGR24->YUV420P bilinear", .BGR24, .YUV420P, 3, {.Bilinear})
	bench("ARGB->YUV420P bilinear", .ARGB, .YUV420P, 4, {.Bilinear})
	bench("BGRA->YUV420P bilinear", .BGRA, .YUV420P, 4, {.Bilinear})
	bench("RGB24->YUV420P point", .RGB24, .YUV420P, 3, {.Point})
	bench("RGBA->YUV420P point", .RGBA, .YUV420P, 4, {.Point})
	bench_keyed()
}

// ---------------------------------------------------------------------------
// The keyed-geometry scale, which is what render_eval_keyed_geom does per
// frame per keyed clip when scale is animated. Measured here because the
// obvious suspect (the resample itself) turned out not to be the cost: an
// animated scale changes the destination rect every frame, and an SwsContext
// is configured for fixed src/dst dimensions, so "just cache the context"
// cannot work — every frame legitimately needs a new one.
//
// Two shapes are timed, both scaling the same crop sub-rect of the same
// stage with Bilinear RGBA->RGBA:
//   * fresh   — sws_getContext + sws_scale + sws_freeContext, i.e. the
//               current render_eval_keyed_geom code path exactly.
//   * ctx only— just the getContext/freeContext pair with no scaling at all,
//               which isolates the per-frame context cost from the resample.
// A third row times a pure nearest-neighbour resize of the same rect, as the
// reference for "what does resampling actually cost when the setup is free".
// ---------------------------------------------------------------------------

KF_STAGE_W :: 1920
KF_STAGE_H :: 1080

// kf_src_alloc builds the benchmark's source image.
//
// Deliberately SMOOTH, not a sawtooth. A high-frequency pattern is the wrong
// control for comparing two resamplers: swscale's bilinear runs a filter
// kernel several source pixels wide while a 2x2 bilinear only touches four,
// and on per-pixel-alternating content the two legitimately disagree by ~65
// per byte no matter which is correct. Real video is band-limited, so a smooth
// image is the case where any correct bilinear must agree closely, and a
// disagreement there is a bug rather than a filter-width argument.
kf_src_alloc :: proc() -> ([]u8, int) {
	src := make([]u8, KF_STAGE_W * KF_STAGE_H * 4)
	kf_fill_smooth(src, KF_STAGE_W, KF_STAGE_H)
	return src, KF_STAGE_W * 4
}

// kf_fill_smooth writes the band-limited test image into an arbitrary size.
kf_fill_smooth :: proc(src: []u8, w, h: int) {
	for y in 0 ..< h {
		for x in 0 ..< w {
			// Two low spatial frequencies plus a mild vignette, so every
			// channel varies across the image and no plane is flat.
			lum := 110.0 +
				70.0 * math.sin(f64(x) / 37.0) *
				math.cos(f64(y) / 29.0) +
				25.0 * math.sin(f64(x+y) / 11.0)
			off := (y * w + x) * 4
			src[off + 0] = u8(clamp(lum + 18.0, 0.0, 255.0))
			src[off + 1] = u8(clamp(lum, 0.0, 255.0))
			src[off + 2] = u8(clamp(lum - 21.0, 0.0, 255.0))
			src[off + 3] = 255
		}
	}
}

kf_rect :: proc(i: int) -> (srcw, srch, rw, rh: int) {
	step := i % 64
	srcw = 1600
	srch = 900
	rw = srcw - step * 2
	rh = srch - step
	return
}

bench_ms :: proc(b: ^Kf_Bench, shape: Kf_Shape, iters: int) -> f64 {
	b.counter = 0
	kf_run(b, shape)
	t0 := time.tick_now()
	for _ in 0 ..< iters {
		kf_run(b, shape)
	}
	return f64(time.tick_since(t0)) / 1e6 / f64(iters)
}

// Kf_Shape selects which keyed-scale implementation to time. A named enum
// rather than a bare int, so a typo'd case is a compile error instead of a
// silently-skipped benchmark row.
Kf_Shape :: enum u32 {
	// The current render_eval_keyed_geom path: a fresh context every frame,
	// because an animated scale changes the destination rect every frame.
	Fresh_Animated,
	// Fresh context, constant 1:1 geometry. swscale has an unscaled
	// special-case for this that never runs the filter.
	Unscaled_1to1,
	// Fresh context, constant 0.5x geometry. The control for Unscaled_1to1:
	// same code path as Fresh_Animated and the same non-trivial scale, but
	// the dimensions never change. Comparing this against Fresh_Animated is
	// what separates "the filter is expensive" from "changing dims is
	// expensive".
	Filtered_Half,
	// The same non-trivial scale with no context and no filter: the floor a
	// purpose-built kernel could reach on this geometry.
	Nearest_Half,
	// Nearest on the animated geometry, i.e. the same source/destination
	// relationship the current path handles.
	Nearest_Animated,
	// Our replacement kernel on the animated geometry — the number the
	// compositor change is actually judged on.
	Kernel_Animated,
	// ...and on a fixed 0.5x downscale, next to swscale's own 0.5x row.
	Kernel_Half,
	// The 1 -> 3 keyframed-scale case TODO.md Active 4 reports: keyed setup
	// sizes the decode stage at the maximum keyed scale, so a 3x track at
	// 1080p makes every frame resample 5760x3240 down to 1920x1080. This is
	// the worst shape for the kernel -- a 9-tap footprint and 18.7 Mpx of
	// source read per output frame.
	Stage3x_Swscale,
	Stage3x_Kernel,
}

// Stage3x dimensions, named because they appear in three places and are the
// whole point of the Stage3x rows.
STAGE3X_W, STAGE3X_H :: 5760, 3240
DST3X_W, DST3X_H :: 1920, 1080

// Kf_Bench is the whole benchmark's mutable state. One flat struct instead of
// four closures over shared locals: the state is small, has one owner, and the
// enclosing proc is the only writer.
Kf_Bench :: struct {
	src:        []u8,
	src_stride: int,
	dst:        []u8,
	dst_ref:    []u8,
	// The 1->3 stage shape needs its own buffers: 5760x3240x4 is 75 MB, too
	// big to be the shared 1920x1080 stage, and the Stage3x rows run both
	// resamplers over the SAME source so the comparison is honest.
	big:        []u8,
	big_stride: int,
	big_dst:    []u8,
	counter:         int,
	fixed_ctx:       ^sws.Context,
	reinit_ctx:      ^sws.Context,
	scale_failures:  int,
	reinit_failures: int,
}

// kf_scale_rect runs one sws_scale using b.fixed_ctx as the context.
kf_scale_rect :: proc(b: ^Kf_Bench, srcw, srch, rw, rh: int) {
	sln: [1][^]u8 = {raw_data(b.src)}
	ls:  [4]c.int = {c.int(b.src_stride), 0, 0, 0}
	dln: [1][^]u8 = {raw_data(b.dst)}
	dls: [4]c.int = {c.int(rw * 4), 0, 0, 0}
	ret := sws.scale(
		b.fixed_ctx,
		cast([^][^]u8)&sln[0], cast([^]c.int)&ls[0], 0, c.int(srch),
		cast([^][^]u8)&dln[0], cast([^]c.int)&dls[0],
	)
	// A silently-failing scale makes a row look artificially fast, which is
	// how the first version of this benchmark produced a bogus 0.138 ms/frame
	// row. Count failures instead of ignoring them.
	if ret < 0 {
		b.scale_failures += 1
	}
}

kf_make_ctx :: proc(srcw, srch, rw, rh: int) -> ^sws.Context {
	return sws.getContext(
		c.int(srcw), c.int(srch), avutil.PixelFormat.RGBA,
		c.int(rw), c.int(rh), avutil.PixelFormat.RGBA,
		sws.Flags{.Bilinear}, nil, nil, nil,
	)
}

// kf_nearest is a plain scalar nearest-neighbour resample: the reference for
// "what a trivial loop over this geometry costs", so the number that matters
// is the gap between it and swscale's filtered path.
kf_nearest :: proc(b: ^Kf_Bench, srcw, srch, rw, rh: int) {
	xstep := srcw / rw
	ystep := srch / rh
	for y in 0 ..< rh {
		sp := cast([^]u8)(uintptr(raw_data(b.src)) + uintptr(y * ystep * b.src_stride))
		dp := cast([^]u8)(uintptr(raw_data(b.dst)) + uintptr(y * rw * 4))
		for x in 0 ..< rw {
			sp2 := cast([^]u8)(uintptr(sp) + uintptr(x * xstep * 4))
			dp2 := cast([^]u8)(uintptr(dp) + uintptr(x * 4))
			dp2[0] = sp2[0]
			dp2[1] = sp2[1]
			dp2[2] = sp2[2]
			dp2[3] = sp2[3]
		}
	}
}

kf_run :: proc(b: ^Kf_Bench, shape: Kf_Shape) {
	srcw, srch := 1600, 900
	#partial switch shape {
	case .Fresh_Animated:
		a, bb, rw, rh := kf_rect(b.counter)
		b.counter += 1
		ctx := kf_make_ctx(a, bb, rw, rh)
		defer sws.freeContext(ctx)
		b.fixed_ctx = ctx
		kf_scale_rect(b, a, bb, rw, rh)
		b.fixed_ctx = nil
	case .Unscaled_1to1:
		ctx := kf_make_ctx(srcw, srch, srcw, srch)
		defer sws.freeContext(ctx)
		b.fixed_ctx = ctx
		kf_scale_rect(b, srcw, srch, srcw, srch)
		b.fixed_ctx = nil
	case .Filtered_Half:
		rw, rh := srcw / 2, srch / 2
		ctx := kf_make_ctx(srcw, srch, rw, rh)
		defer sws.freeContext(ctx)
		b.fixed_ctx = ctx
		kf_scale_rect(b, srcw, srch, rw, rh)
		b.fixed_ctx = nil
	case .Nearest_Half:
		kf_nearest(b, srcw, srch, srcw / 2, srch / 2)
	case .Nearest_Animated:
		a, bb, rw, rh := kf_rect(b.counter)
		b.counter += 1
		kf_nearest(b, a, bb, rw, rh)
	case .Kernel_Animated:
		a, bb, rw, rh := kf_rect(b.counter)
		b.counter += 1
		yuv.rgba_resample(
			raw_data(b.src), b.src_stride, 0, 0, a, bb,
			raw_data(b.dst), rw * 4, rw, rh,
		)
	case .Kernel_Half:
		yuv.rgba_resample(
			raw_data(b.src), b.src_stride, 0, 0, srcw, srch,
			raw_data(b.dst), (srcw / 2) * 4, srcw / 2, srch / 2,
		)
	case .Stage3x_Swscale:
		// kf_scale_rect reads b.src/b.src_stride and writes b.dst, so point
		// those at the 3x buffers for the duration of this case.
		saved_src, saved_stride, saved_dst := b.src, b.src_stride, b.dst
		b.src, b.src_stride, b.dst = b.big, b.big_stride, b.big_dst
		ctx := kf_make_ctx(STAGE3X_W, STAGE3X_H, DST3X_W, DST3X_H)
		defer sws.freeContext(ctx)
		b.fixed_ctx = ctx
		kf_scale_rect(b, STAGE3X_W, STAGE3X_H, DST3X_W, DST3X_H)
		b.fixed_ctx = nil
		b.src, b.src_stride, b.dst = saved_src, saved_stride, saved_dst
	case .Stage3x_Kernel:
		yuv.rgba_resample(
			raw_data(b.big), b.big_stride, 0, 0, STAGE3X_W, STAGE3X_H,
			raw_data(b.big_dst), DST3X_W * 4, DST3X_W, DST3X_H,
		)
	}
}

// kf_debug_small prints a tiny hand-checkable case: an 8x8 horizontal ramp
// downscaled to 4x4, from both resamplers. A weight that is crossed, a shift
// that is off by one, or a mis-signed edge clamp all show up here as numbers
// that can be checked by hand, which a 1.44 Mpx mean cannot localise.
kf_debug_small :: proc(b: ^Kf_Bench) {
	W, H, DW, DH :: 8, 8, 4, 4
	small := make([]u8, W * H * 4)
	defer delete(small)
	for y in 0 ..< H {
		for x in 0 ..< W {
			off := (y * W + x) * 4
			v := u8(x * 30)
			small[off + 0] = v
			small[off + 1] = v
			small[off + 2] = v
			small[off + 3] = 255
		}
	}
	ours := make([]u8, DW * DH * 4)
	defer delete(ours)
	theirs := make([]u8, DW * DH * 4)
	defer delete(theirs)

	ctx := kf_make_ctx(W, H, DW, DH)
	b.fixed_ctx = ctx
	sln: [1][^]u8 = {raw_data(small)}
	ls: [4]c.int = {c.int(W * 4), 0, 0, 0}
	dln: [1][^]u8 = {raw_data(theirs)}
	dls: [4]c.int = {c.int(DW * 4), 0, 0, 0}
	sws.scale(ctx, cast([^][^]u8)&sln[0], cast([^]c.int)&ls[0], 0, c.int(H),
		cast([^][^]u8)&dln[0], cast([^]c.int)&dls[0])
	sws.freeContext(ctx)
	b.fixed_ctx = nil

	yuv.rgba_resample(raw_data(small), W * 4, 0, 0, W, H, raw_data(ours), DW * 4, DW, DH)

	fmt.printf("\n8x8 ramp -> 4x4 (row means, source row = 0,30,60,90,120,150,180,210):\n")
	for y in 0 ..< DH {
		orow, trow := 0, 0
		for x in 0 ..< DW {
			orow += int(ours[(y*DW+x)*4])
			trow += int(theirs[(y*DW+x)*4])
		}
		fmt.printf("  row %d: ours=%3d swscale=%3d\n", y, orow / DW, trow / DW)
	}
}

// kf_vs_swscale reports how far our kernel lands from swscale's bilinear on
// the same geometry. Not a byte-equality test — the weights are 8-bit and the
// accumulation order differs, so it cannot be byte-identical, and the point of
// the swap was to change those bytes. What matters is that it is the same
// picture to within a few quantisation steps and not systematically brighter or
// darker, which is what a botched weight or a mis-signed shift would look like.
kf_vs_swscale :: proc(b: ^Kf_Bench) -> (mean_abs: f64, max_abs: int) {
	geom := [4][4]int {
		{1600, 900, 1600, 900}, // 1:1 -> must be an exact copy
		{1600, 900, 800, 450},  // 0.5x downscale
		{800, 450, 1600, 900},  // 2x upscale
		// The case TODO.md Active 4 actually reports: a scale 1->3 keyframe
		// track makes keyed setup size the decode stage at 3x (5760x3240 at
		// 1080p), so every frame box-averages 18.7 Mpx down to 2.07 Mpx -- a
		// 3x downscale with a 9-tap footprint, the worst case for the kernel.
		{5760, 3240, 1920, 1080},
	}
	total: i64 = 0
	count: i64 = 0
	max_abs = 0
	for g in geom {
		srcw, srch, rw, rh := g[0], g[1], g[2], g[3]
		// A source sized to THIS case, not the shared stage: the 3x case needs
		// 5760x3240 and the shared stage is 1920x1080, so passing it through
		// tripped rgba_resample's bounds assert (correctly).
		case_src := make([]u8, srcw * srch * 4)
		defer delete(case_src)
		kf_fill_smooth(case_src, srcw, srch)
		stride := srcw * 4

		buf_ref := make([]u8, rw * rh * 4)
		buf_our := make([]u8, rw * rh * 4)
		defer delete(buf_ref)
		defer delete(buf_our)

		sln: [1][^]u8 = {raw_data(case_src)}
		ls:  [4]c.int = {c.int(stride), 0, 0, 0}
		dln: [1][^]u8 = {raw_data(buf_ref)}
		dls: [4]c.int = {c.int(rw * 4), 0, 0, 0}
		ctx := kf_make_ctx(srcw, srch, rw, rh)
		sws.scale(
			ctx,
			cast([^][^]u8)&sln[0], cast([^]c.int)&ls[0], 0, c.int(srch),
			cast([^][^]u8)&dln[0], cast([^]c.int)&dls[0],
		)
		sws.freeContext(ctx)

		yuv.rgba_resample(
			raw_data(case_src), stride, 0, 0, srcw, srch,
			raw_data(buf_our), rw * 4, rw, rh,
		)
		for k in 0 ..< rw * rh * 4 {
			d := int(buf_ref[k]) - int(buf_our[k])
			if d < 0 {
				d = -d
			}
			if d > max_abs {
				max_abs = d
			}
			total += i64(d)
			count += 1
		}
		fmt.printf(
			"  %-16s vs swscale: mean_abs=%.2f max_abs=%d\n",
			fmt.tprintf("%dx%d->%dx%d", srcw, srch, rw, rh),
			f64(total) / f64(count), max_abs,
		)
		total = 0
		count = 0
		max_abs = 0
	}
	mean_abs = 0
	return
}

// kf_equivalence runs the same animated frames through the current path
// (fresh context every frame) and a candidate, into separate buffers, and
// byte-compares the region each one claims to have written.
//
// This exists because the reinit-context row measured 32x faster than the
// fresh-context row while making the identical sws_scale call, which is only
// possible if the two are not doing the same work. A resampler that is fast
// because it quietly produced a different picture is worse than the slow one,
// so no timing here means anything until this passes.
kf_equivalence :: proc(b: ^Kf_Bench, other: Kf_Shape) -> (match: bool, diff_at: int) {
	FRAMES :: 6
	diff_at = -1
	match = true
	buf_a := make([]u8, KF_STAGE_W * KF_STAGE_H * 4)
	buf_b := make([]u8, KF_STAGE_W * KF_STAGE_H * 4)
	defer delete(buf_a)
	defer delete(buf_b)
	defer b.dst = nil

	for i in 0 ..< FRAMES {
		mem.zero_slice(buf_a)
		mem.zero_slice(buf_b)
		b.counter = i
		b.dst = buf_a
		kf_run(b, .Fresh_Animated)
		b.counter = i
		b.dst = buf_b
		kf_run(b, other)

		_, _, rw, rh := kf_rect(i)
		for k in 0 ..< rw * rh * 4 {
			if buf_a[k] != buf_b[k] {
				match = false
				diff_at = k
				return
			}
		}
	}
	return
}

bench_keyed :: proc() {
	ITERS :: 40
	src, src_stride := kf_src_alloc()
	dst := make([]u8, KF_STAGE_W * KF_STAGE_H * 4)
	defer delete(src)
	defer delete(dst)
	big := make([]u8, STAGE3X_W * STAGE3X_H * 4)
	big_dst := make([]u8, DST3X_W * DST3X_H * 4)
	defer delete(big)
	defer delete(big_dst)
	kf_fill_smooth(big, STAGE3X_W, STAGE3X_H)
	b := Kf_Bench {
		src = src, src_stride = src_stride, dst = dst,
		big = big, big_stride = STAGE3X_W * 4, big_dst = big_dst,
	}
	defer if b.fixed_ctx != nil {
		sws.freeContext(b.fixed_ctx)
	}

	shapes := [?]Kf_Shape {
		.Fresh_Animated,
		.Unscaled_1to1,
		.Filtered_Half,
		.Nearest_Half,
		.Nearest_Animated,
		.Kernel_Animated,
		.Kernel_Half,
		.Stage3x_Swscale,
		.Stage3x_Kernel,
	}
	labels := [?]string {
		"swscale bilinear, animated (current)",
		"swscale bilinear, 1:1 (unscaled path)",
		"swscale bilinear, 0.5x fixed",
		"nearest, 0.5x fixed",
		"nearest, animated",
		"yuv.rgba_resample, animated",
		"yuv.rgba_resample, 0.5x fixed",
		"swscale bilinear, 5760x3240 -> 1920x1080",
		"yuv.rgba_resample, 5760x3240 -> 1920x1080",
	}

	times: [9]f64
	broken := false
	for i in 0 ..< len(shapes) {
		b.counter = 0
		b.scale_failures = 0
		times[i] = bench_ms(&b, shapes[i], ITERS)
		if b.scale_failures > 0 {
			broken = true
		}
	}

	kf_debug_small(&b)
	kf_vs_swscale(&b)

	fmt.printf("\nkeyed scale, crop 1600x900, iters=%d\n", ITERS)
	for i in 0 ..< len(times) {
		note := ""
		if i < 2 && broken {
			note = "  (BROKEN: scale errors)"
		}
		fmt.printf("  %-38s %8.3f ms/frame%s\n", labels[i], times[i], note)
	}
	if times[0] > 0 && times[1] > 0 {
		fmt.printf(
			"  %-38s %8.1fx\n",
			"=> animated vs the unscaled fast path", times[0] / times[1],
		)
	}
	if times[7] > 0 && times[8] > 0 {
		fmt.printf(
			"  %-38s %8.1fx\n",
			"=> Stage3x (1->3 keyframes) swscale vs kernel", times[7] / times[8],
		)
	}
	if times[2] > 0 && times[3] > 0 {
		fmt.printf(
			"  %-38s %8.1fx\n",
			"=> swscale filter vs nearest (0.5x)", times[2] / times[3],
		)
	}
	if times[0] > 0 && times[4] > 0 {
		fmt.printf(
			"  %-38s %8.1fx\n",
			"=> swscale animated vs nearest animated", times[0] / times[4],
		)
	}
	if times[0] > 0 && times[5] > 0 {
		fmt.printf(
			"  %-38s %8.1fx\n",
			"=> swscale animated vs our kernel (animated)", times[0] / times[5],
		)
	}
	if times[2] > 0 && times[6] > 0 {
		fmt.printf(
			"  %-38s %8.1fx\n",
			"=> swscale vs our kernel (0.5x)", times[2] / times[6],
		)
	}
}
