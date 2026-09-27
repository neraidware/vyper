// vendor/yuv: RGBA geometry resampling, the replacement for the swscale call
// the export compositor used to make per frame per keyed clip.
//
// Why this exists, measured (scripts/gate.sh bench, crop 1600x900):
//
//	swscale bilinear, animated dst   15.60 ms/frame   <- what it did
//	swscale bilinear, 1:1             0.185 ms/frame
//	swscale bilinear, 0.5x            7.116 ms/frame
//	nearest, animated dst             0.993 ms/frame
//
// Two things that measurement settles, both of which contradicted the obvious
// guesses:
//
//   - The per-frame sws_getContext is NOT the cost. getContext+freeContext
//     alone is ~0.1 ms, three orders below the total. Caching the context (or
//     reusing one via sws_init_context) cannot fix this; in the benchmark a
//     reinit variant measured 32x "faster" only because it silently produced
//     different bytes, which a byte-compare caught and assumption would not.
//
//   - The cost is swscale's generic *filtered* RGBA->RGBA resampler, at
//     roughly 11 ms per megapixel of OUTPUT (15.6 ms at 1.44 Mpx vs 7.1 ms at
//     0.36 Mpx is the same rate, so it tracks output pixels). Its 1:1 unscaled
//     special case is ~80x cheaper, which is why only clips with a non-unit
//     scale ever showed the problem.
//
// A plain scalar nearest loop does the same geometry 15.7x faster than swscale
// while doing strictly less work, so the headroom is enormous and the only
// question is how much quality to keep. This keeps the quality and takes the
// speed:
//
//   - Downscale (the common case: the stage is decoded at max scale precisely
//     so the display box can be smaller) uses an area/box filter. For
//     minification this is both the faster choice and the correct one — point
//     sampling drops source pixels when shrinking, which is what makes a
//     slowly-scaling clip crawl with shimmer.
//   - Upscale uses bilinear, where point sampling would visibly stair-step.
//   - 1:1 is a row copy.
//
// This deliberately changes output bytes versus the old swscale call: it is a
// rendering-quality decision, not a bug fix. Callers compare decoded content,
// not a byte hash of the intermediate, so nothing depends on the old bytes.
//
// Everything here is allocation-free and takes caller-owned memory. The
// compositor calls it once per keyed clip per frame on a hot path, so a
// per-call table build would be a per-frame heap hit (see the x-bound tables
// this file used to allocate: they are gone in favour of an incremental
// 16.16 walk that needs no state beyond two registers).
package yuv

import "base:intrinsics"
import "core:mem"
import "core:simd"

// ONE is the 16.16 fixed-point scale. Weights and axis positions are exact
// integers, so output is bit-reproducible run to run — a float path would make
// export output depend on the FPU, which is precisely the drift the export
// matrix exists to catch.
ONE :: 65536

// rgba_resample resamples the RGBA sub-rectangle (src_x, src_y, src_w, src_h)
// out of a source image with row pitch `src_stride` bytes into a destination
// image with row pitch `dst_stride`, at dst_w x dst_h. Every destination pixel
// is written, so the caller may size the destination exactly.
//
// Returns false only for geometry that cannot be resampled (a non-positive
// dimension on either side). Callers treat that as a bug, not a recoverable
// error: every dimension here comes from render_kf_geom_rect, which already
// clamps to at least 1, so a zero here means that clamp regressed.
rgba_resample :: proc(
	src: [^]u8, src_stride: int,
	src_x, src_y, src_w, src_h: int,
	dst: [^]u8, dst_stride: int,
	dst_w, dst_h: int,
) -> bool {
	if src_w <= 0 || src_h <= 0 || dst_w <= 0 || dst_h <= 0 {
		return false
	}
	// The crop must lie inside the source, or the row pointer arithmetic below
	// walks off the buffer. Assert rather than clamp: a crop outside its own
	// stage is a geometry bug, and clamping would hide it behind
	// plausible-looking pixels instead of stopping work (AGENTS.md §6).
	assert(src_x >= 0 && src_y >= 0)
	assert(src_x + src_w <= src_stride / 4)

	if dst_w == src_w && dst_h == src_h {
		rgba_copy_rows(src, src_stride, src_x, src_y, src_w, src_h, dst, dst_stride)
		return true
	}
	if dst_w <= src_w && dst_h <= src_h {
		rgba_box_downscale(
			src, src_stride, src_x, src_y, src_w, src_h,
			dst, dst_stride, dst_w, dst_h,
		)
		return true
	}
	rgba_bilinear_resample(
		src, src_stride, src_x, src_y, src_w, src_h,
		dst, dst_stride, dst_w, dst_h,
	)
	return true
}

// rgba_copy_rows copies an axis-aligned block with no filtering. This is the
// 1:1 case, and the same operation the compositor's fixed-scale branch already
// performs, so a clip that lands on an exact integer box pays nothing.
rgba_copy_rows :: proc(
	src: [^]u8, src_stride: int,
	src_x, src_y, src_w, src_h: int,
	dst: [^]u8, dst_stride: int,
) {
	row_bytes := src_w * 4
	for y in 0 ..< src_h {
		sp := cast([^]u8)(uintptr(src) + uintptr((src_y + y) * src_stride + src_x * 4))
		dp := cast([^]u8)(uintptr(dst) + uintptr(y * dst_stride))
		mem.copy(dp, sp, row_bytes)
	}
}

// rgba_box_downscale area-averages when shrinking.
//
// This path exists because bilinear is NOT a minification filter, and finding
// that out cost a real bug: for an exact 2:1 downscale the 16.16 step is
// 2*ONE, so the two bilinear taps land on src x and x+1 with zero weight on
// the second and the "filtered" result is a point sample of every other pixel
// (measured: row mean 90 where a correct average is 105). Adjacent taps only
// filter while magnifying. Shrinking must spread taps across the whole source
// footprint, which is what a box does.
//
// The accumulator is a plain u32 holding one packed RGBA word per source pixel,
// NOT a Vec. The obvious SIMD move -- splat each pixel's RGBA word across four
// i32 lanes and let simd.add accumulate -- is a pessimisation: a broadcast costs
// more than the scalar add it replaces, and it was the source of a real bug,
// because this package's load4 returns FOUR pixels (lane i is pixel i) and
// summing it per tap counted 4 pixels per tap and saturated to 255. The loop's
// real parallelism is 4 taps deep, not 4 channels wide.
rgba_box_downscale :: proc(
	src: [^]u8, src_stride: int,
	src_x, src_y, src_w, src_h: int,
	dst: [^]u8, dst_stride: int,
	dst_w, dst_h: int,
) {
	x_step := (src_w * ONE) / dst_w
	y_step := (src_h * ONE) / dst_h

	y_pos := 0
	for dy in 0 ..< dst_h {
		y_end := y_pos + y_step
		sy0 := y_pos >> 16
		sy1 := y_end >> 16
		// A footprint is never empty: under heavy minification several
		// destination rows land inside the same source row.
		if sy1 <= sy0 {
			sy1 = sy0 + 1
		}
		y_pos = y_end
		row_stride := src_stride

		dp := cast(^u8)(uintptr(dst) + uintptr(dy * dst_stride))
		x_pos := 0
		for dx in 0 ..< dst_w {
			x_end := x_pos + x_step
			sx0 := x_pos >> 16
			sx1 := x_end >> 16
			if sx1 <= sx0 {
				sx1 = sx0 + 1
			}
			x_pos = x_end
			span := sx1 - sx0
			rows := sy1 - sy0

			// Per-CHANNEL accumulators, never one packed u32. Summing packed
			// RGBA words carries between bytes: four taps of a=255 overflow the
			// alpha byte and spill into blue (measured 9 where 15 was correct).
			// u16 is exact for any footprint up to 257 pixels.
			// A 1x1 footprint is a copy, and it dominates the near-unity
			// animated scale: at 0.92 the 16.16 step is ~1.085 source pixels,
			// so most destination pixels land inside a single source pixel and
			// only the occasional one spans a boundary. Short-circuiting before
			// the accumulate matters more than the accumulate itself, because
			// the loops below have data-dependent trip counts that neither
			// unroll nor predict well.
			if span == 1 && rows == 1 {
				sp := cast(^u8)(uintptr(src) + uintptr((src_y+sy0)*row_stride + (src_x+sx0)*4))
				intrinsics.unaligned_store(
					cast(^u32)(cast(^u8)(uintptr(dp) + uintptr(dx * 4))),
					load_word(sp, 0),
				)
				continue
			}

			a0, a1, a2, a3: u32 = 0, 0, 0, 0
			off := (src_y+sy0) * row_stride + (src_x+sx0) * 4
			for sy in 0 ..< rows {
				row := cast(^u8)(uintptr(src) + uintptr(off))
				i := 0
				// 4x unrolled over the footprint: the common animated case is a
				// 2x2 box, so this covers every tap of it and the next output
				// pixel's loads are already in flight.
				for i + 4 <= span {
					px := load_word(row, i * 4)
					a0 += px & 0xFF
					a1 += (px >> 8) & 0xFF
					a2 += (px >> 16) & 0xFF
					a3 += (px >> 24) & 0xFF
					px = load_word(row, i*4 + 4)
					a0 += px & 0xFF
					a1 += (px >> 8) & 0xFF
					a2 += (px >> 16) & 0xFF
					a3 += (px >> 24) & 0xFF
					px = load_word(row, i*4 + 8)
					a0 += px & 0xFF
					a1 += (px >> 8) & 0xFF
					a2 += (px >> 16) & 0xFF
					a3 += (px >> 24) & 0xFF
					px = load_word(row, i*4 + 12)
					a0 += px & 0xFF
					a1 += (px >> 8) & 0xFF
					a2 += (px >> 16) & 0xFF
					a3 += (px >> 24) & 0xFF
					i += 4
				}
				for i < span {
					px := load_word(row, i * 4)
					a0 += px & 0xFF
					a1 += (px >> 8) & 0xFF
					a2 += (px >> 16) & 0xFF
					a3 += (px >> 24) & 0xFF
					i += 1
				}
				off += row_stride
			}
			store_px_avg(cast(^u8)(uintptr(dp) + uintptr(dx * 4)), a0, a1, a2, a3, u32(span * rows))
		}
	}
}

// load_word reads one packed RGBA pixel as a u32. Byte order is irrelevant: the
// four bytes are summed and normalized independently, and stored back in the
// order they came out.
load_word :: proc(p: ^u8, off: int) -> u32 {
	return intrinsics.unaligned_load(cast(^u32)(cast(^u8)(uintptr(p) + uintptr(off))))
}

// store_px_avg normalizes a box sum and writes one packed RGBA pixel.
//
// Divide-free: a multiply by a precomputed reciprocal, with a 1x1 footprint
// (sum IS the pixel) skipping the normalize entirely. Four 32-bit integer
// divides per output pixel is ~34M cycles across a 1.44 Mpx frame; the
// reciprocal is computed once per pixel and the common 1x1 case not at all.
store_px_avg :: proc(dst: ^u8, r, g, b, a, total: u32) {
	packed: u32
	if total == 1 {
		// 1x1 footprint: the taps ARE the pixel, nothing to normalize.
		packed = (r & 0xFF) | ((g & 0xFF) << 8) | ((b & 0xFF) << 16) | ((a & 0xFF) << 24)
	} else {
		// Multiply by a reciprocal rather than dividing: ONE divide per output
		// pixel (for the reciprocal) instead of four per channel. f32 has a
		// 24-bit mantissa and the operands are 0..255, so the product is
		// within 1 of the exact quotient, and the +0.5 rounds to nearest.
		inv := 1.0 / f32(total)
		packed = (norm_byte(f32(r), inv)) |
			(norm_byte(f32(g), inv) << 8) |
			(norm_byte(f32(b), inv) << 16) |
			(norm_byte(f32(a), inv) << 24)
	}
	intrinsics.unaligned_store(cast(^u32)dst, packed)
}

// norm_byte normalizes one channel sum by the precomputed reciprocal, rounded
// to nearest and clamped to a byte.
norm_byte :: proc(sum: f32, inv: f32) -> u32 {
	return u32(clamp(sum * inv + 0.5, 0.0, 255.0))
}

// rgba_bilinear_resample magnifies with a 2x2 bilinear.
//
// Per-CHANNEL accumulators for the same reason as the box filter: this package's
// load4 returns FOUR pixels (lane i is pixel i's packed RGBA), so multiplying it
// by a splatted weight computes w*pixel0, w*pixel1, w*pixel2, w*pixel3 across the
// four lanes -- four different source pixels, not one output pixel's channels.
// Summing that leaves the taps spread across the lanes instead of combined, and
// the result is garbage (measured mean_abs 75, max_abs 255 against swscale).
// 8-bit-per-axis weights keep every product inside u32: 255 * 256 * 256 = 16.7M.
rgba_bilinear_resample :: proc(
	src: [^]u8, src_stride: int,
	src_x, src_y, src_w, src_h: int,
	dst: [^]u8, dst_stride: int,
	dst_w, dst_h: int,
) {
	x_step := (src_w * ONE) / dst_w
	y_step := (src_h * ONE) / dst_h

	// The four weights always sum to 256*256 whatever the position, so the
	// normalizer is a constant rather than a per-pixel divide.
	norm := 1.0 / f32(256 * 256)

	y_pos := 0
	for dy in 0 ..< dst_h {
		y_end := y_pos + y_step
		sy := y_pos >> 16
		// The top 8 bits of the 16.16 fraction are the per-axis weight, 0..255.
		wy := u32((y_pos >> 8) & 0xFF)
		y_pos = y_end
		// Clamp the second tap instead of branching on it: a footprint that
		// rounds past the last row repeats it, which is what the edge should do.
		sy1 := min(sy + 1, src_h - 1)

		r0 := cast(^u8)(uintptr(src) + uintptr((src_y+sy) * src_stride + src_x * 4))
		r1 := cast(^u8)(uintptr(src) + uintptr((src_y+sy1) * src_stride + src_x * 4))
		dp := cast(^u8)(uintptr(dst) + uintptr(dy * dst_stride))

		x_pos := 0
		for dx in 0 ..< dst_w {
			x_end := x_pos + x_step
			sx := x_pos >> 16
			wx := u32((x_pos >> 8) & 0xFF)
			x_pos = x_end
			sx1 := min(sx + 1, src_w - 1)

			// p00/p10 are the top row and p01/p11 the bottom, so the x weight
			// pairs with the y weight BY ROW. Crossing these two produces a
			// transposed image that still reads as a plausible resample, which
			// is why the swscale comparison in the bench is a gate.
			ix := 256 - wx
			iy := 256 - wy

			ar, ag, ab, aa: u32 = 0, 0, 0, 0
			acc_tap(&ar, &ag, &ab, &aa, r0, sx * 4, wx * iy)
			acc_tap(&ar, &ag, &ab, &aa, r0, sx1 * 4, ix * iy)
			acc_tap(&ar, &ag, &ab, &aa, r1, sx * 4, wx * wy)
			acc_tap(&ar, &ag, &ab, &aa, r1, sx1 * 4, ix * wy)

			packed := norm_byte(f32(ar), norm) |
				(norm_byte(f32(ag), norm) << 8) |
				(norm_byte(f32(ab), norm) << 16) |
				(norm_byte(f32(aa), norm) << 24)
			intrinsics.unaligned_store(cast(^u32)(cast(^u8)(uintptr(dp) + uintptr(dx * 4))), packed)
		}
	}
}

// acc_tap adds one weighted source pixel into the per-channel accumulators.
acc_tap :: proc(r, g, b, a: ^u32, row: ^u8, off: int, w: u32) {
	px := load_word(row, off)
	r^ += (px & 0xFF) * w
	g^ += ((px >> 8) & 0xFF) * w
	b^ += ((px >> 16) & 0xFF) * w
	a^ += ((px >> 24) & 0xFF) * w
}
