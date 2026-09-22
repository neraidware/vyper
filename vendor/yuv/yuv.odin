// vendor/yuv: the two conversion kernels vyper needs to feed its encoders,
// hand-written in Odin SIMD. They replace the previously-pinned external
// libyuv dependency: the math is fixed colorimetry (BT.601 limited range), so
// it cannot drift with an upstream library update, and it removes the system-
// lib build coupling (flake/rpath/Linux-only binding).
//
// rgba_to_nv12: fused color conversion + 2x2 chroma subsample in one pass.
//     Input is the in-memory canvas byte order (R,G,B,A little-endian per
//     pixel), which is libyuv's "ABGR" naming — that naming collision with
//     the raw bytes is why the kernel lives here under our own name.
// nv12_to_i420: planar split of the intermediate NV12 (used only for the
//     planar-YUV420P/libx264 path); Y is a pure row copy, UV deinterleaves.
package yuv

import "base:intrinsics"
import "core:mem"
import "core:simd"

Vec :: #simd [4]i32

bcast :: proc(x: i32) -> Vec {
	return Vec{x, x, x, x}
}

// Coefficient vectors, hoisted to package scope so they're built once instead
// of being re-splatted by y_of/u_of/v_of on every 4-pixel step of every row.
C_66 :: Vec{66, 66, 66, 66}
C_129 :: Vec{129, 129, 129, 129}
C_25 :: Vec{25, 25, 25, 25}
C_128 :: Vec{128, 128, 128, 128}
C_16 :: Vec{16, 16, 16, 16}
C_N38 :: Vec{-38, -38, -38, -38}
C_N74 :: Vec{-74, -74, -74, -74}
C_112 :: Vec{112, 112, 112, 112}
C_N94 :: Vec{-94, -94, -94, -94}
C_N18 :: Vec{-18, -18, -18, -18}
C_0 :: Vec{0, 0, 0, 0}
C_255 :: Vec{255, 255, 255, 255}
C_2 :: Vec{2, 2, 2, 2}

// y_of: per-lane BT.601 limited-range luma, ((66R + 129G + 25B + 128) >> 8) + 16.
y_of :: proc(r, g, b: Vec) -> Vec {
	t := simd.add(simd.mul(C_66, r), simd.add(simd.mul(C_129, g), simd.add(simd.mul(C_25, b), C_128)))
	return simd.add(simd.shr(t, 8), C_16)
}

// u_of / v_of: per-lane chroma pre-clamp, ((-38R - 74G + 112B) >> 8) + 128.
// The >> 8 of the (potentially negative) signed sum already rounds toward
// -inf; adding a 0x8080 bias would double-count the +128.
u_of :: proc(r, g, b: Vec) -> Vec {
	t := simd.add(simd.mul(C_N38, r), simd.add(simd.mul(C_N74, g), simd.mul(C_112, b)))
	return simd.add(simd.shr(t, 8), C_128)
}

v_of :: proc(r, g, b: Vec) -> Vec {
	t := simd.add(simd.mul(C_112, r), simd.add(simd.mul(C_N94, g), simd.mul(C_N18, b)))
	return simd.add(simd.shr(t, 8), C_128)
}

// unpack_rgb: decompose 4 ABGR pixels (16 bytes) into per-lane R, G, B.
unpack_rgb :: proc(px: Vec) -> (r, g, b: Vec) {
	r = simd.bit_and(px, bcast(0xFF))
	g = simd.bit_and(simd.shr(px, 8), bcast(0xFF))
	b = simd.bit_and(simd.shr(px, 16), bcast(0xFF))
	return
}

// pair_sums: horizontal adjacent-pair sums, lane i = v[2i] + v[2i+1]. Lane 0
// of the result is the chroma block for pixel pair (0,1), lane 1 for (2,3).
pair_sums :: proc(v: Vec) -> Vec {
	evens := simd.shuffle(v, v, 0, 2, 0, 2)
	odds := simd.shuffle(v, v, 1, 3, 1, 3)
	return simd.add(evens, odds)
}

// store_y4: write 4 output bytes from the low byte of each lane, clamped.
// Packed as a single 4-byte store instead of 4 scalar lane extracts.
store_y4 :: proc(dst: [^]u8, v: Vec) {
	c := simd.clamp(v, C_0, C_255)
	packed: u32 =
		u32(simd.extract(c, 0)) |
		(u32(simd.extract(c, 1)) << 8) |
		(u32(simd.extract(c, 2)) << 16) |
		(u32(simd.extract(c, 3)) << 24)
	intrinsics.unaligned_store((^u32)(dst), packed)
}

// chroma_of: per-2x2-block chroma from per-pixel row vectors. Each arg holds
// the per-pixel chroma of one source row; the block value is the average over
// the 2x2 area, (row0_pairs + row1_pairs + 2) >> 2, clamped. Lanes 0,1 of the
// result are the two output chroma samples (U or V, pair of pixels).
chroma_of :: proc(pairs0_u, pairs1_u: Vec, pairs0_v, pairs1_v: Vec) -> (u, v: Vec) {
	u = simd.clamp(simd.shr(simd.add(simd.add(pair_sums(pairs0_u), pair_sums(pairs1_u)), C_2), 2), C_0, C_255)
	v = simd.clamp(simd.shr(simd.add(simd.add(pair_sums(pairs0_v), pair_sums(pairs1_v)), C_2), 2), C_0, C_255)
	return
}

// store_uv4: interleave two U,V pairs (lanes 0,1 of each) into 4 output
// bytes U0 V0 U1 V1, as a single 4-byte store instead of 4 scalar extracts.
store_uv4 :: proc(dst: [^]u8, u, v: Vec) {
	packed: u32 =
		u32(simd.extract(u, 0)) |
		(u32(simd.extract(v, 0)) << 8) |
		(u32(simd.extract(u, 1)) << 16) |
		(u32(simd.extract(v, 1)) << 24)
	intrinsics.unaligned_store((^u32)(dst), packed)
}

load4 :: proc(p: ^u8) -> Vec {
	return intrinsics.unaligned_load(cast(^Vec)p)
}

/*
rgba_to_nv12 converts a width*height RGBA canvas (4 bytes/pixel, R,G,B,A in
memory) into an NV12 buffer: a width*height Y plane plus an interleaved U,V
plane (width bytes per chroma row). Input is never scaled — 1:1 conversion
into the encoder-input frames. The SIMD path converts 4 pixels per walk and
always runs over the full 4-aligned portion of the row; only the trailing
0-3 pixels of a non-multiple-of-4 width fall back to the scalar kernel, and
that fallback writes chroma too (previously silently dropped).
*/
rgba_to_nv12 :: proc(
	width, height: int,
	src: [^]u8,
	src_stride: int,
	dst_y: [^]u8,
	dst_y_stride: int,
	dst_uv: [^]u8,
	dst_uv_stride: int,
) -> bool {
	if width <= 0 || height <= 0 {
		return false
	}

	simd_w := width - width % 4 // widest 4-aligned prefix of the row
	tail_start := simd_w // 0..3 leftover columns, handled scalar

	for row in 0 ..< height / 2 {
		y0 := 2 * row
		ly0 := y0 * dst_y_stride
		uo := row * dst_uv_stride

		// SIMD main loop: 4 columns (a 2x2-pixel-pair-wide chroma block) per step.
		for x in 0 ..< simd_w / 4 {
			px := 16 * x
			dy := 4 * x
			pt := load4(&src[y0 * src_stride + px])
			pb := load4(&src[(y0 + 1) * src_stride + px])
			rt, gt, bt := unpack_rgb(pt)
			rb, gb, bb := unpack_rgb(pb)
			store_y4(&dst_y[ly0 + dy], y_of(rt, gt, bt))
			store_y4(&dst_y[ly0 + dst_y_stride + dy], y_of(rb, gb, bb))
			cu, cv := chroma_of(u_of(rt, gt, bt), u_of(rb, gb, bb), v_of(rt, gt, bt), v_of(rb, gb, bb))
			store_uv4(&dst_uv[uo + 4 * x], cu, cv)
		}

		// Scalar tail for the last 0-3 columns of a non-multiple-of-4 width.
		// Processed two columns at a time so each NV12 chroma pair (2 columns)
		// gets its full 2x2 average; a single leftover column averages only
		// the two rows. The previous per-column walk wrote two UV bytes per
		// column, which clobbered the pair's V and walked into the next row.
		x := tail_start
		for x < width {
			yt0, ut0, vt0 := px_yuv(&src[y0 * src_stride], x)
			yb0, ub0, vb0 := px_yuv(&src[(y0 + 1) * src_stride], x)
			dst_y[ly0 + x] = yt0
			dst_y[ly0 + dst_y_stride + x] = yb0
			n := 2
			sum_u := int(ut0) + int(ub0)
			sum_v := int(vt0) + int(vb0)
			if x + 1 < width {
				yt1, ut1, vt1 := px_yuv(&src[y0 * src_stride], x + 1)
				yb1, ub1, vb1 := px_yuv(&src[(y0 + 1) * src_stride], x + 1)
				dst_y[ly0 + x + 1] = yt1
				dst_y[ly0 + dst_y_stride + x + 1] = yb1
				n = 4
				sum_u += int(ut1) + int(ub1)
				sum_v += int(vt1) + int(vb1)
			}
			dst_uv[uo + x] = u8((sum_u + n / 2) / n)
			dst_uv[uo + x + 1] = u8((sum_v + n / 2) / n)
			x += 2
		}
	}

	if height % 2 == 1 {
		ly := (height - 1) * dst_y_stride
		ls := (height - 1) * src_stride
		for x in 0 ..< simd_w / 4 {
			px := 16 * x
			rt, gt, bt := unpack_rgb(load4(&src[ls + px]))
			store_y4(&dst_y[ly + 4 * x], y_of(rt, gt, bt))
		}
		for x in tail_start ..< width {
			yt, _, _ := px_yuv(&src[ls], x)
			dst_y[ly + x] = yt
		}
	}
	return true
}

// px_yuv: scalar one-pixel luma+chroma from its y-relative row.
px_yuv :: proc(row: [^]u8, x: int) -> (y, u, v: u8) {
	return scalar_rgb_to_yuv(pixel(row, x))
}

pixel :: proc(row: [^]u8, x: int) -> u32 {
	return intrinsics.unaligned_load((^u32)(&row[4 * x]))
}

// scalar_rgb_to_yuv: BT.601 limited range, per-pixel.
scalar_rgb_to_yuv :: proc(p: u32) -> (y, u, v: u8) {
	r := i32(p >> 0 & 0xFF)
	g := i32(p >> 8 & 0xFF)
	b := i32(p >> 16 & 0xFF)
	y = u8(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16)
	u = u8(clamp(((-38 * r - 74 * g + 112 * b) >> 8) + 128, 0, 255))
	v = u8(clamp(((112 * r - 94 * g - 18 * b) >> 8) + 128, 0, 255))
	return
}

/*
nv12_to_i420 splits an NV12 buffer (Y plane + interleaved U,V) into three
planar YUV420P planes. Y is a row copy; U and V deinterleave the shared
chroma plane. Both inputs and outputs come from avutil.image_alloc, so the
stride contract is fixed by the caller. The deinterleave uses a SIMD
load-shuffle-store over 4-pixel-pair (16-byte) blocks instead of a per-pixel
scalar loop; a scalar tail handles the remaining 0-3 pairs of a row.
*/
nv12_to_i420 :: proc(
	width, height: int,
	src_y: [^]u8,
	src_y_stride: int,
	src_uv: [^]u8,
	src_uv_stride: int,
	dst_y: [^]u8,
	dst_y_stride: int,
	dst_u: [^]u8,
	dst_u_stride: int,
	dst_v: [^]u8,
	dst_v_stride: int,
) {
	for r in 0 ..< height {
		mem.copy(&dst_y[r * dst_y_stride], &src_y[r * src_y_stride], width)
	}

	chroma_w := width / 2
	chroma_h := height / 2
	simd_pairs := chroma_w - chroma_w % 4 // groups of 4 UV pairs (16 bytes) at a time

	// #simd [16]u8 so simd.shuffle is a byte-wise permute (pshufb). An
	// unaligned 16-byte load of U0 V0 U1 V1... shuffled with even/odd lane
	// masks becomes the sequential U and V runs.
	U8Vec :: #simd [16]u8

	for r in 0 ..< chroma_h {
		src_row := r * src_uv_stride
		u_row := r * dst_u_stride
		v_row := r * dst_v_stride

		i := 0
		for i < simd_pairs {
			block := intrinsics.unaligned_load(cast(^U8Vec)&src_uv[src_row + 2 * i])
			split := simd.shuffle(block, block, 0, 2, 4, 6, 8, 10, 12, 14, 1, 3, 5, 7, 9, 11, 13, 15)
			for k in 0 ..< 4 {
				dst_u[u_row + i + k] = u8(simd.extract(split, k))
				dst_u[u_row + i + 4 + k] = u8(simd.extract(split, 4 + k))
				dst_v[v_row + i + k] = u8(simd.extract(split, 8 + k))
				dst_v[v_row + i + 4 + k] = u8(simd.extract(split, 12 + k))
			}
			i += 8
		}
		for i < chroma_w {
			dst_u[u_row + i] = src_uv[src_row + 2 * i]
			dst_v[v_row + i] = src_uv[src_row + 2 * i + 1]
			i += 1
		}
	}
}
