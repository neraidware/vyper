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

// y_of: per-lane BT.601 limited-range luma, ((66R + 129G + 25B + 128) >> 8) + 16.
y_of :: proc(r, g, b: Vec) -> Vec {
	t := simd.add(simd.mul(bcast(66), r), simd.add(simd.mul(bcast(129), g), simd.add(simd.mul(bcast(25), b), bcast(128))))
	return simd.add(simd.shr(t, 8), bcast(16))
}

// u_of / v_of: per-lane chroma pre-clamp, ((-38R - 74G + 112B) >> 8) + 128.
// The >> 8 of the (potentially negative) signed sum already rounds toward
// -inf; adding a 0x8080 bias would double-count the +128.
u_of :: proc(r, g, b: Vec) -> Vec {
	t := simd.add(simd.mul(bcast(-38), r), simd.add(simd.mul(bcast(-74), g), simd.mul(bcast(112), b)))
	return simd.add(simd.shr(t, 8), bcast(128))
}

v_of :: proc(r, g, b: Vec) -> Vec {
	t := simd.add(simd.mul(bcast(112), r), simd.add(simd.mul(bcast(-94), g), simd.mul(bcast(-18), b)))
	return simd.add(simd.shr(t, 8), bcast(128))
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
store_y4 :: proc(dst: [^]u8, v: Vec) {
	c := simd.clamp(v, bcast(0), bcast(255))
	for i in 0 ..< 4 {
		dst[i] = u8(simd.extract(c, i))
	}
}

// chroma_of: per-2x2-block chroma from per-pixel row vectors. Each arg holds
// the per-pixel chroma of one source row; the block value is the average over
// the 2x2 area, (row0_pairs + row1_pairs + 2) >> 2, clamped. Lanes 0,1 of the
// result are the two output chroma samples (U or V, pair of pixels).
chroma_of :: proc(pairs0_u, pairs1_u: Vec, pairs0_v, pairs1_v: Vec) -> (u, v: Vec) {
	u = simd.clamp(simd.shr(simd.add(simd.add(pair_sums(pairs0_u), pair_sums(pairs1_u)), bcast(2)), 2), bcast(0), bcast(255))
	v = simd.clamp(simd.shr(simd.add(simd.add(pair_sums(pairs0_v), pair_sums(pairs1_v)), bcast(2)), 2), bcast(0), bcast(255))
	return
}

load4 :: proc(p: ^u8) -> Vec {
	return intrinsics.unaligned_load(cast(^Vec)p)
}

/*
rgba_to_nv12 converts a width*height RGBA canvas (4 bytes/pixel, R,G,B,A in
memory) into an NV12 buffer: a width*height Y plane plus an interleaved U,V
plane (width bytes per chroma row). Input is never scaled — 1:1 conversion
into the encoder-input frames. The SIMD path converts 4 pixels per walk;
widths that aren't a multiple of 4 take the identical scalar fallback.
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
	if width % 4 != 0 {
		for row in 0 ..< height / 2 {
			for x in 0 ..< width {
				yt, ut, vt := px_yuv(&src[2 * row * src_stride], x)
				yb, ub, vb := px_yuv(&src[(2 * row + 1) * src_stride], x)
				dst_y[2 * row * dst_y_stride + x] = yt
				dst_y[(2 * row + 1) * dst_y_stride + x] = yb
				_ = vt
				_ = vb
				_ = ut
				_ = ub
			}
		}
		if height % 2 == 1 {
			ly := (height - 1) * dst_y_stride
			ls := (height - 1) * src_stride
			for x in 0 ..< width {
				yt, _, _ := px_yuv(&src[ls], x)
				dst_y[ly + x] = yt
			}
		}
		return true
	}

	for row in 0 ..< height / 2 {
		y0 := 2 * row
		ly0 := y0 * dst_y_stride

		for x in 0 ..< width / 4 {
			px := 16 * x
			dy := 4 * x
			pt := load4(&src[y0 * src_stride + px])
			pb := load4(&src[(y0 + 1) * src_stride + px])
			rt, gt, bt := unpack_rgb(pt)
			rb, gb, bb := unpack_rgb(pb)
			store_y4(&dst_y[ly0 + dy], y_of(rt, gt, bt))
			store_y4(&dst_y[ly0 + dst_y_stride + dy], y_of(rb, gb, bb))
			cu, cv := chroma_of(u_of(rt, gt, bt), u_of(rb, gb, bb), v_of(rt, gt, bt), v_of(rb, gb, bb))
			ci := 4 * x
			uo := row * dst_uv_stride
			dst_uv[uo + ci + 0] = u8(simd.extract(cu, 0))
			dst_uv[uo + ci + 1] = u8(simd.extract(cv, 0))
			dst_uv[uo + ci + 2] = u8(simd.extract(cu, 1))
			dst_uv[uo + ci + 3] = u8(simd.extract(cv, 1))
		}
	}

	if height % 2 == 1 {
		ly := (height - 1) * dst_y_stride
		ls := (height - 1) * src_stride
		for x in 0 ..< width / 4 {
			px := 16 * x
			rt, gt, bt := unpack_rgb(load4(&src[ls + px]))
			store_y4(&dst_y[ly + 4 * x], y_of(rt, gt, bt))
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
stride contract is fixed by the caller.
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
	for r in 0 ..< chroma_h {
		for i in 0 ..< chroma_w {
			dst_u[r * dst_u_stride + i] = src_uv[r * src_uv_stride + 2 * i]
			dst_v[r * dst_v_stride + i] = src_uv[r * src_uv_stride + 2 * i + 1]
		}
	}
}