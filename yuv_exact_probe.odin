// Byte-exactness probe for the exporter's RGBA -> encoder-input conversion
// (VYPER_YUV_EXACT_PROBE). S1c wants that conversion on the GPU, but the only
// acceptable contract is byte-identical to what swscale produces today -- an
// exported file must not move because of a refactor. Reproducing it in a shader
// is not a guess: swscale computes Y and chroma at FULL source resolution into
// int16 (input.c rgb24ToY_c / rgb24ToUV_c) and then lets the scaler decimate
// the chroma 2:1, in 15-bit fixed point, with a dither add (output.c
// yuv2plane1_8_c / yuv2nv12cX_c). The tap structure of that decimation is the
// part worth measuring rather than assuming, so this probe asks swscale
// directly and prints the bytes.
//
// It also verifies, in the other direction: once a candidate formula exists,
// `check` compares it byte-for-byte against the same swscale context the
// exporter builds. Mode is the env value: "dump" prints, "check" gates.

package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import avutil "vendor/ffmpeg/avutil"
import sws "vendor/ffmpeg/swscale"

// The exporter's destination linesize: av_image_alloc with align 32 rounds each
// plane up to 32 bytes. Mirrored by hand because only image_alloc is bound
// (there is no image_free), and the stride is part of what the probe is
// measuring against -- deriving it here keeps the two in step by inspection.
YUV_PROBE_ALIGN :: 32

yuv_probe_linesize :: proc(w: c.int) -> c.int {
	return (w + YUV_PROBE_ALIGN - 1) / YUV_PROBE_ALIGN * YUV_PROBE_ALIGN
}

// The exporter's own conversion setup, mirrored exactly: same context flags,
// same destination stride. If this drifts from enc_convert_finish /
// rend_enc_video_frame the probe is validating a conversion nobody ships, so
// the flags below are deliberately the same expression rather than an
// independent choice.
yuv_probe_convert :: proc(
	rgba: []u8,
	w, h: c.int,
	dst: ^[4][^]u8,
	ls: ^[4]c.int,
	ctx: ^^sws.Context,
) -> bool {
	slice: [1][^]u8 = {raw_data(rgba)}
	src_ls: [4]c.int = {w * 4, 0, 0, 0}
	if ctx^ == nil {
		ctx^ = sws.getContext(
			w,
			h,
			avutil.PixelFormat.RGBA,
			w,
			h,
			avutil.PixelFormat.NV12,
			sws.Flags{.Bilinear},
			nil,
			nil,
			nil,
		)
		if ctx^ == nil {
			return false
		}
	}
	return sws.scale(
		ctx^,
		cast([^][^]u8)&slice[0],
			&src_ls[0],
		0,
		h,
			cast([^][^]u8)raw_data(dst),
		cast([^]c.int)ls,
	) > 0
}

// Deterministic input so the printed bytes can be reproduced outside the
// binary (the formula was solved against this exact sequence). A gradient
// would be smoother than real content and could hide a coefficient error on
// low-entropy input, so this is a full-amplitude LCG instead.
yuv_probe_fill_rgba :: proc(px: []u8, seed: u32) {
	s := seed
	for i in 0 ..< len(px) {
		s = s * 1664525 + 1013904223
		px[i] = u8(s >> 24)
	}
}

// Sized for the widest row the probe is asked to print; fmt.bprintf
// truncates rather than panics, so too small here silently loses columns.
yuv_probe_hex_row :: proc(label: string, row: [^]u8, n: int) {
	line: [8192]u8
	off := 0
	for i in 0 ..< n {
		off += len(fmt.bprintf(line[off:], "%02x ", row[i]))
	}
	fmt.println(label, string(line[:off]))
}

// dump prints the reference bytes. Deliberately small: the chroma decimation's
// tap structure is only legible when a handful of rows can be compared by eye,
// and a big frame hides exactly the phase/alignment detail being looked for.
yuv_probe_dump :: proc(w, h: c.int) -> int {
	rgba := make([]u8, w * h * 4)
	defer delete(rgba)
	yuv_probe_fill_rgba(rgba, 0x12345678)
	y_ls := yuv_probe_linesize(w)
	buf := make([]u8, y_ls * h * 3 / 2)
	defer delete(buf)
	data: [4][^]u8 = {raw_data(buf), raw_data(buf[y_ls * h:]), nil, nil}
	ls: [4]c.int = {y_ls, y_ls, 0, 0}
	ctx: ^sws.Context
	if !yuv_probe_convert(rgba, w, h, &data, &ls, &ctx) {
		fmt.println("yuv-exact: sws.scale failed")
		return 1
	}
	defer sws.freeContext(ctx)
	fmt.println("yuv-exact: w", w, "h", h, "y_ls", y_ls, "uv_ls", ls[1])
	fmt.println("--- rgba (R channel per pixel) ---")
	row: [8192]u8
	for y in 0 ..< h {
		off := 0
		for x in 0 ..< w {
			off += len(fmt.bprintf(row[off:], "%02x ", rgba[(y * w + x) * 4]))
		}
		fmt.printf("rgba r%-2d %s\n", y, string(row[:off]))
	}
	fmt.println("--- Y ---")
	for y in 0 ..< h {
		yuv_probe_hex_row(fmt.tprintf("Y%-2d    ", y), data[0][y * ls[0]:], int(w))
	}
	fmt.println("--- UV ---")
	uv_w := w / 2
	for y in 0 ..< h / 2 {
		yuv_probe_hex_row(fmt.tprintf("UV%-2d   ", y), data[1][y * ls[1]:], int(uv_w * 2))
	}
	return 0
}


// The chroma decimation is separable (swscale h-scales then v-filters), so each
// axis can be isolated by making the pattern constant along the OTHER one: if
// every pixel in a row is identical the horizontal taps collapse to their sum
// and whatever varies down the output column IS the vertical response, and the
// transpose gives the horizontal one. Against a flat gray reference, a single
// saturated-red line is a clean impulse, so the response is the taps directly
// rather than something to be inferred from content.
yuv_probe_taps :: proc(w, h: c.int) -> int {
	rgba := make([]u8, w * h * 4)
	defer delete(rgba)
	y_ls := yuv_probe_linesize(w)
	buf := make([]u8, y_ls * h * 3 / 2)
	defer delete(buf)
	data: [4][^]u8 = {raw_data(buf), raw_data(buf[y_ls * h:]), nil, nil}
	ls: [4]c.int = {y_ls, y_ls, 0, 0}
	ctx: ^sws.Context
	uv_w, uv_h := w / 2, h / 2
	// Reference: flat gray. Chroma of neutral gray is the code value the
	// offsets fold around, so this is the baseline every delta is taken from.
	for i in 0 ..< w * h {
		rgba[i * 4 + 0] = 128
		rgba[i * 4 + 1] = 128
		rgba[i * 4 + 2] = 128
		rgba[i * 4 + 3] = 255
	}
	if !yuv_probe_convert(rgba, w, h, &data, &ls, &ctx) {
		fmt.println("yuv-exact: sws.scale failed (gray)")
		return 1
	}
	fmt.println("taps: flat gray reference, chroma row0 =")
	yuv_probe_hex_row("gray U0  ", data[1][0:], int(uv_w))
	yuv_probe_hex_row("gray V0  ", data[1][uv_w:], int(uv_w))
	// Horizontal impulse: one full column red, all rows identical.
	imp_x := w / 2
	for y in 0 ..< h {
		px := (y * w + imp_x) * 4
		rgba[px + 0] = 255
		rgba[px + 1] = 0
		rgba[px + 2] = 0
	}
	if !yuv_probe_convert(rgba, w, h, &data, &ls, &ctx) {
		fmt.println("yuv-exact: sws.scale failed (h impulse)")
		return 1
	}
	fmt.println("taps: horizontal impulse at x =", imp_x)
	for r in 0 ..< uv_h {
		yuv_probe_hex_row(fmt.tprintf("himp U%-2d", r), data[1][r * ls[1]:], int(uv_w))
	}
	// Vertical impulse: one full row red, all columns identical.
	for i in 0 ..< w * h {
		rgba[i * 4 + 0] = 128
		rgba[i * 4 + 1] = 128
		rgba[i * 4 + 2] = 128
		rgba[i * 4 + 3] = 255
	}
	imp_y := h / 2
	for x in 0 ..< w {
		px := (imp_y * w + x) * 4
		rgba[px + 0] = 255
		rgba[px + 1] = 0
		rgba[px + 2] = 0
	}
	if !yuv_probe_convert(rgba, w, h, &data, &ls, &ctx) {
		fmt.println("yuv-exact: sws.scale failed (v impulse)")
		return 1
	}
	fmt.println("taps: vertical impulse at y =", imp_y, "(U per output row, col 0)")
	line: [8192]u8
	off := 0
	for y in 0 ..< uv_h {
		off += len(fmt.bprintf(line[off:], "%02x ", data[1][y * ls[1]]))
	}
	fmt.println("vimp U   ", string(line[:off]))
	return 0
}

// One conversion, one pattern, fresh context. Every impulse measurement in
// yuv_probe_taps reuses a single sws context across calls, so anything cached
// in that context would be indistinguishable from "this pattern has no
// effect". A single conversion per process removes that explanation.
// Same input, same context, N conversions, chroma printed after each. If the
// answer changes between call 1 and call 2 then swscale's first conversion on
// a fresh context is not equivalent to its steady state -- which would mean the
// exporter's frame 1 differs from frame 2+ for identical input.
yuv_probe_warm :: proc(w, h: c.int, calls: int) -> int {
	rgba := make([]u8, w * h * 4)
	defer delete(rgba)
	for i in 0 ..< w * h {
		rgba[i * 4 + 0] = 128
		rgba[i * 4 + 1] = 128
		rgba[i * 4 + 2] = 128
		rgba[i * 4 + 3] = 255
	}
	for x in 0 ..< w {
		px := ((h / 2) * w + x) * 4
		rgba[px + 0] = 255
		rgba[px + 1] = 0
		rgba[px + 2] = 0
	}
	y_ls := yuv_probe_linesize(w)
	buf := make([]u8, y_ls * h * 3 / 2)
	defer delete(buf)
	data: [4][^]u8 = {raw_data(buf), raw_data(buf[y_ls * h:]), nil, nil}
	ls: [4]c.int = {y_ls, y_ls, 0, 0}
	ctx: ^sws.Context
	uv_w := w / 2
	for call in 0 ..< calls {
		if !yuv_probe_convert(rgba, w, h, &data, &ls, &ctx) {
			fmt.println("yuv-exact: sws.scale failed on call", call)
			return 1
		}
		line: [8192]u8
		off := 0
		for r in 0 ..< h / 2 {
			off += len(fmt.bprintf(line[off:], "%02x ", data[1][r * ls[1]]))
		}
		fmt.println("call", call, ":", string(line[:off]))
	}
	defer sws.freeContext(ctx)
	return 0
}

// One red PIXEL, whole chroma plane dumped. Line impulses give the axis
// profiles convolved with the other axis's total gain; a single pixel gives
// the separable 2D kernel itself, which is what the shader has to reproduce.
// Pattern that varies ONLY along x (every row identical). The vertical filter
// then sees a constant column signal and collapses to a gain, so a chroma row
// is the horizontal filter's response to the column pattern directly. That is
// the axis the pixel impulse could not separate, because its two footprints
// convolve.
yuv_probe_hrow :: proc(w, h: c.int) -> int {
	rgba := make([]u8, w * h * 4)
	defer delete(rgba)
	yuv_probe_fill_rgba(rgba, 0xC0FFEE11)
	for y in 0 ..< h {
		for x in 0 ..< w {
			px := (y * w + x) * 4
			rgba[px + 0] = rgba[x * 4 + 0]
			rgba[px + 1] = rgba[x * 4 + 1]
			rgba[px + 2] = rgba[x * 4 + 2]
			rgba[px + 3] = 255
		}
	}
	y_ls := yuv_probe_linesize(w)
	buf := make([]u8, y_ls * h * 3 / 2)
	defer delete(buf)
	data: [4][^]u8 = {raw_data(buf), raw_data(buf[y_ls * h:]), nil, nil}
	ls: [4]c.int = {y_ls, y_ls, 0, 0}
	ctx: ^sws.Context
	if !yuv_probe_convert(rgba, w, h, &data, &ls, &ctx) {
		fmt.println("yuv-exact: sws.scale failed")
		return 1
	}
	defer sws.freeContext(ctx)
	uv_w := w / 2
	fmt.println("hrow: w", w, "chroma width", uv_w)
	for r in 0 ..< h / 2 {
		yuv_probe_hex_row(fmt.tprintf("U%-2d     ", r), data[1][r * ls[1]:], int(uv_w))
	}
	return 0
}

// The impulse COLOR is a parameter, not a constant. The first version hardcoded
// red, and red alone cannot distinguish "swscale's chroma kernel is genuinely
// asymmetric" from "this probe is misreading the plane": a red impulse must
// push U below the neutral 128, so a positive-U sample anywhere in its
// footprint is already suspicious, and a reader who assumes a bug in swscale
// rather than in the probe has no way to tell which. Sweeping the primary
// colors gives the sign pattern a control: if each color's U/V deltas track
// the matrix row it should perturb, the footprint is real.
// The arbiter: swscale and the reference, byte for byte, on the same input.
//
// The pattern deliberately varies along BOTH axes. An earlier fixture used a
// full-period LCG whose every row was copied from row 0, which makes the
// vertical stage collapse to a DC gain -- a 1D fit then looks legitimate
// when the real kernel is 2D, and the fit "succeeds" while describing
// nothing. Rows must differ here or this comparison cannot fail when it
// should.
yuv_probe_verify :: proc(w, h: c.int, flat: bool) -> int {
	rgba := make([]u8, w * h * 4)
	defer delete(rgba)
	// Row-constant variant: with every luma row identical the vertical
	// filter collapses to unity gain regardless of its taps, so swscale's
	// byte exposes the per-pixel chroma P directly. That separates the two
	// things a mismatch could mean -- wrong P, or wrong kernel -- which the
	// combined run cannot.
	for y in 0 ..< h {
		sy := y
		if flat {
			sy = 0
		}
		for x in 0 ..< w {
			i := (y * w + x) * 4
			rgba[i + 0] = u8((x * 7 + sy * 29 + 3) & 255)
			rgba[i + 1] = u8((x * 11 + sy * 53 + 71) & 255)
			rgba[i + 2] = u8((x * 17 + sy * 97 + 149) & 255)
			rgba[i + 3] = 255
		}
	}
	y_ls := yuv_probe_linesize(w)
	buf := make([]u8, y_ls * h * 3 / 2)
	defer delete(buf)
	data: [4][^]u8 = {raw_data(buf), raw_data(buf[y_ls * h:]), nil, nil}
	ls: [4]c.int = {y_ls, y_ls, 0, 0}
	ctx: ^sws.Context
	if !yuv_probe_convert(rgba, w, h, &data, &ls, &ctx) {
		fmt.println("yuv-exact: sws.scale failed")
		return 1
	}
	defer sws.freeContext(ctx)

	uv_w := w / 2
	ref := make([]u8, y_ls * h * 3 / 2)
	defer delete(ref)
	su := make([]i32, w * h / 2)
	defer delete(su)
	sv := make([]i32, w * h / 2)
	defer delete(sv)
	yuv_ref_rgba_to_nv12(rgba, int(w), int(h), int(y_ls), int(y_ls), ref, su, sv)

	// Compare only the regions swscale actually writes. The chroma rows are
	// uv_w*2 bytes wide but sit at stride y_ls, so the tail of each row is
	// untouched padding -- comparing it would report a mismatch that is not
	// a conversion difference but a buffer we never asked anyone to fill.
	mismatches := 0
	first := 0
	for y in 0 ..< h {
		for x in 0 ..< w {
			a := buf[y * y_ls + x]
			b := ref[y * y_ls + x]
			if a != b {
				mismatches += 1
				if first < 8 {
					fmt.println(
						"Y  mismatch at x =",
						x,
						", y =",
						y,
						"swscale =",
						a,
						"ref =",
						b,
					)
					first += 1
				}
			}
		}
	}
	uv_base := y_ls * h
	for k in 0 ..< h / 2 {
		for c in 0 ..< uv_w * 2 {
			a := buf[uv_base + k * y_ls + c]
			b := ref[uv_base + k * y_ls + c]
			if a != b {
				mismatches += 1
				if first < 8 {
					plane := "U"
					if c & 1 == 1 {
						plane = "V"
					}
					fmt.println(
						plane,
						" mismatch at",
						c / 2,
						",",
						k,
						"swscale =",
						a,
						"ref =",
						b,
					)
					first += 1
				}
			}
		}
	}
	fmt.println("yuv-exact: verify", w, "x", h, "mismatches =", mismatches)
	if mismatches == 0 {
		return 0
	}
	return 1
}

yuv_probe_pixel :: proc(w, h: c.int, py, px: c.int, col: int, bgv: int) -> int {
	// R, G, B of the single impulse; the plane constants are the YUV
	// primaries, and white/gray are the neutral controls.
	imp: [4][3]u8 = {
		{255, 0, 0},
		{0, 255, 0},
		{0, 0, 255},
		{255, 255, 255},
	}
	// col 4..6 selects a whole-frame solid fill of the red/green/blue primary
	// (col - 4 indexes imp). The solid flag is derived BEFORE the clamp, or the
	// clamp silently rewrites 4 to 0 and the mode never fires.
	solid := col >= 4 && col <= 6
	ci := col
	if solid {
		ci = col - 4
	} else if ci < 0 || ci > 3 {
		ci = 0
	}
	rgba := make([]u8, w * h * 4)
	defer delete(rgba)
	// Background is a parameter because a 128-gray background makes the
	// impulse deltas small (-7), and two unequal kernel weights can round to
	// the SAME byte at that magnitude -- which is exactly how a 2-tap
	// horizontal kernel was "confirmed" here when it is not. Black raises
	// the delta enough that unequal weights cannot hide.
	bgb := u8(bgv & 255)
	bg: [3]u8 = {bgb, bgb, bgb}
	if solid {
		bg = imp[ci]
	}
	for i in 0 ..< w * h {
		rgba[i * 4 + 0] = bg[0]
		rgba[i * 4 + 1] = bg[1]
		rgba[i * 4 + 2] = bg[2]
		rgba[i * 4 + 3] = 255
	}
	off := (py * w + px) * 4
	rgba[off + 0] = imp[ci][0]
	rgba[off + 1] = imp[ci][1]
	rgba[off + 2] = imp[ci][2]
	y_ls := yuv_probe_linesize(w)
	buf := make([]u8, y_ls * h * 3 / 2)
	defer delete(buf)
	data: [4][^]u8 = {raw_data(buf), raw_data(buf[y_ls * h:]), nil, nil}
	ls: [4]c.int = {y_ls, y_ls, 0, 0}
	ctx: ^sws.Context
	if !yuv_probe_convert(rgba, w, h, &data, &ls, &ctx) {
		fmt.println("yuv-exact: sws.scale failed")
		return 1
	}
	defer sws.freeContext(ctx)
	uv_w := w / 2
	names := [4]string{"red", "green", "blue", "white"}
	fmt.println(
		"single",
		names[ci],
		"pixel at y =",
		py,
		"x =",
		px,
		"(chroma",
		uv_w,
		"x",
		h / 2,
		")",
	)
	// Dump the chroma plane as swscale actually laid it out: full rows of
	// ls[1] bytes, so the U/V interleave and the row stride are visible
	// rather than assumed. The previous version printed "U" from offset 0 and
	// "V" from offset uv_w on the theory that NV12 is [U row][V row]; on that
	// reading the impulse showed up only under the V label and at a column
	// nowhere near the one the impulse should touch, which means the theory
	// was wrong and the offsets, not the kernel, were the thing under test.
	// Printing the bytes settles the layout in one run.
	fmt.println("chroma plane rows, ls[1] =", ls[1], "bytes each, uv_w =", uv_w)
	for r in 0 ..< h / 2 {
		yuv_probe_hex_row(fmt.tprintf("c%-2d     ", r), data[1][r * ls[1]:], int(ls[1]))
	}
	return 0
}

yuv_probe_single :: proc(w, h: c.int, vertical: bool) -> int {
	rgba := make([]u8, w * h * 4)
	defer delete(rgba)
	for i in 0 ..< w * h {
		rgba[i * 4 + 0] = 128
		rgba[i * 4 + 1] = 128
		rgba[i * 4 + 2] = 128
		rgba[i * 4 + 3] = 255
	}
	if vertical {
		for x in 0 ..< w {
			px := ((h / 2) * w + x) * 4
			rgba[px + 0] = 255
			rgba[px + 1] = 0
			rgba[px + 2] = 0
		}
	} else {
		// w/4, NOT w/2: swscale builds chroma at chrSrcW = w/2 width
		// (utils.c initFilter over c->chrSrcW/c->chrDstW), so the chroma
		// plane only ever reads the left half of the source. An impulse at
		// w/2 is outside its support and correctly does nothing.
		for y in 0 ..< h {
			px := (y * w + w / 4) * 4
			rgba[px + 0] = 255
			rgba[px + 1] = 0
			rgba[px + 2] = 0
		}
	}
	y_ls := yuv_probe_linesize(w)
	buf := make([]u8, y_ls * h * 3 / 2)
	defer delete(buf)
	data: [4][^]u8 = {raw_data(buf), raw_data(buf[y_ls * h:]), nil, nil}
	ls: [4]c.int = {y_ls, y_ls, 0, 0}
	ctx: ^sws.Context
	if !yuv_probe_convert(rgba, w, h, &data, &ls, &ctx) {
		fmt.println("yuv-exact: sws.scale failed")
		return 1
	}
	defer sws.freeContext(ctx)
	uv_w := w / 2
	dir := "horizontal"
	if vertical {
		dir = "vertical"
	}
	fmt.println("single", dir, "impulse at", w / 2)
	for r in 0 ..< h {
		yuv_probe_hex_row(fmt.tprintf("Y%-2d     ", r), data[0][r * ls[0]:], int(w))
	}
	for r in 0 ..< h / 2 {
		yuv_probe_hex_row(fmt.tprintf("U%-2d     ", r), data[1][r * ls[1]:], int(uv_w))
	}
	return 0
}

yuv_exact_probe_run :: proc() -> int {
	mode, _ := os.lookup_env_alloc("VYPER_YUV_EXACT_PROBE", context.temp_allocator)
	n: c.int = 8
	if idx := strings.index(mode, ":"); idx >= 0 {
		if parsed, ok := strconv.parse_int(mode[idx + 1:]); ok {
			n = c.int(parsed)
		}
	}
	if strings.has_prefix(mode, "hrow") {
		return yuv_probe_hrow(n, n)
	}
		if strings.has_prefix(mode, "pix:") {
		// pix:<size>:<py>:<px>[:<color>]
		// pix:<size>:<py>:<px>[:<color>] -- the size is its own field, so parse the
		// fields rather than slicing the tail after the first colon (which
		// leaves "32:16:8" and silently falls back to the default size).
		fields := strings.split(mode, ":")
		py, px: c.int = 16, 8
		if len(fields) > 1 {
			if v, ok := strconv.parse_int(fields[1]); ok {
				n = c.int(v)
			}
		}
		if len(fields) > 2 {
			if v, ok := strconv.parse_int(fields[2]); ok {
				py = c.int(v)
			}
		}
		if len(fields) > 3 {
			if v, ok := strconv.parse_int(fields[3]); ok {
				px = c.int(v)
			}
		}
		col: int = 0
		if len(fields) > 4 {
			if v, ok := strconv.parse_int(fields[4]); ok {
				col = int(v)
			}
		}
		bgv: int = 128
		if len(fields) > 5 {
			if v, ok := strconv.parse_int(fields[5]); ok {
				bgv = int(v)
			}
		}
		return yuv_probe_pixel(n, n, py, px, col, bgv)
	}
	if strings.has_prefix(mode, "warm") {
		return yuv_probe_warm(n, n, 4)
	}
	if strings.has_prefix(mode, "himp") {
		return yuv_probe_single(n, n, false)
	}
	if strings.has_prefix(mode, "vimp") {
		return yuv_probe_single(n, n, true)
	}
	if strings.has_prefix(mode, "taps") {
		return yuv_probe_taps(n, n)
	}
	if strings.has_prefix(mode, "dump") {
		return yuv_probe_dump(n, n)
	}
	if strings.has_prefix(mode, "flat") {
		return yuv_probe_verify(n, n, true)
	}
	if strings.has_prefix(mode, "verify") {
		return yuv_probe_verify(n, n, false)
	}
	fmt.println("yuv-exact: need VYPER_YUV_EXACT_PROBE=\"dump[:N]\"")
	return 2
}
