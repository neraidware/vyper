// Byte-exact CPU reference for swscale's RGBA -> NV12 conversion, at the
// geometry the exporter actually uses.
//
// This exists to be GROUND TRUTH, not to be fast. The shipped conversion is
// swscale, and the S1c plan is to replace it with a GPU shader that must
// produce identical bytes. A shader cannot be debugged against "it looks
// right", so it needs a second, independently written implementation that
// agrees byte-for-byte on every input. That is this file. When the shader
// lands, the gate will run swscale, this, and the shader against each other
// and require all three to be identical -- one pairwise anchor is not enough,
// because a bug shared by two of the three would still pass.
//
// Consequently this allocates and keeps every intermediate live. That is
// deliberate and is not a style violation: the shipped fast path is the
// shader, and this file runs once per gate invocation on one frame. Being
// transparently correct is worth more here than being tidy, because every
// shortcut taken to avoid an allocation is a place the reference could
// silently disagree with swscale and the gate would agree with the
// reference.
//
// The coefficients are transcribed from libswscale/utils.c:704-714, the
// branch taken for the default BT.601 colorspace, which is what
// sws_getContext(..., SWS_BILINEAR) selects. They are literals rather than
// float recomputation so this file cannot drift if FFmpeg's rounding
// changes; if FFmpeg changes them, this file is what should fail loudly,
// and the fix belongs here and not in the shader.
//
// Luma sums to 219/255, not 1: limited range with a +16 pedestal. Chroma
// carries the separate 224/255 scale. Both come from the same table and
// neither may be "simplified" to full range.
package main

// Fixed-point layout, transcribed from libswscale.
YUV_REF_SHIFT       :: 15
YUV_REF_ONE         :: 1 << YUV_REF_SHIFT

// Input coefficients (utils.c:704-714).
YUV_REF_RY :: 8414
YUV_REF_GY :: 16519
YUV_REF_BY :: 3208
YUV_REF_RU :: -4862
YUV_REF_GU :: -9528
YUV_REF_BU :: 14393
YUV_REF_RV :: 14393
YUV_REF_GV :: -12059
YUV_REF_BV :: -2329

// Luma pedestal: 16<<SHIFT for limited range plus half an LSB, so the shift
// rounds instead of truncating. Solved against swscale over 65,536 random
// pixels with zero mismatches.
YUV_REF_LUMA_BIAS :: 540928

// Chroma horizontal siting: one sample per TWO input pixels, summed. This is
// input.c's rgb24ToUV_half_c reading src1[6*i+0] and src1[6*i+3] -- two
// adjacent pixels. The coefficient pair is applied to the SUM, not to each
// pixel, which is what makes the effective per-pixel weight one half.
YUV_REF_CHROMA_H_TAPS :: 2

// Chroma vertical kernel: [2 7 7 2]/18 over luma rows 2k-1 .. 2k+2.
// MEASURED, not derived: a single impulse at luma row y moves chroma row
// y>>1 by -7 and the adjacent row by -2 (up when y is even, down when odd),
// and touches no other row. That adjacent-row spill is what rules out the
// plain 2x2 box a naive reading of "4:2:0" would assume.
//
// Carried as 14-bit normalized coefficients, not as an exact division by 18,
// because that is what swscale's scaler does and the rounding is observable:
// dividing the weighted sum by 18 disagreed with swscale on 1435 of 4096
// chroma bytes, almost all of them off by one. round(w/18 << 14) gives
// 1820, 6372, 6372, 1820 -- which sum to exactly 16384, so the kernel is
// still unity gain and the >> below is the only scaling.
YUV_REF_CHROMA_V_C0 :: 1820
YUV_REF_CHROMA_V_C1 :: 6372
YUV_REF_CHROMA_V_C2 :: 6372
YUV_REF_CHROMA_V_C3 :: 1820
YUV_REF_CHROMA_V_NORM :: 14

// Rounding half-add for the input converter.
YUV_REF_CHROMA_H_BIAS :: 1 << (YUV_REF_SHIFT - 6)

// Final narrowing: the 14-bit filter normalization plus the fact that the
// converter's shift leaves the 8-bit value at bit 6. NOT a bare >>7, which
// is what swscale's own yuv2plane1_8_c uses; the difference is the whole
// off-by-two this file had first. Neutral lands at 8192 = 128<<6, which is
// the check -- with >>7 the neutral would be 64.
YUV_REF_CHROMA_OUT_SHIFT :: YUV_REF_CHROMA_V_NORM + 6

yuv_ref_clip8 :: proc(v: i32) -> u8 {
	if v < 0 {
		return 0
	}
	if v > 255 {
		return 255
	}
	return u8(v)
}

yuv_ref_clamp_row :: proc(row, h: int) -> int {
	if row < 0 {
		return 0
	}
	if row > h - 1 {
		return h - 1
	}
	return row
}

// One luma row of RGBA -> one row of horizontally-sited 15-bit chroma.
yuv_ref_chroma_row :: proc(rgba: []u8, w: int, u_out, v_out: []i32) {
	for c in 0 ..< w / YUV_REF_CHROMA_H_TAPS {
		i0 := c * YUV_REF_CHROMA_H_TAPS * 4
		i1 := i0 + 4
		r := i32(rgba[i0 + 0]) + i32(rgba[i1 + 0])
		g := i32(rgba[i0 + 1]) + i32(rgba[i1 + 1])
		b := i32(rgba[i0 + 2]) + i32(rgba[i1 + 2])
		u_out[c] =
			(YUV_REF_RU * r + YUV_REF_GU * g + YUV_REF_BU * b + 256 * YUV_REF_ONE + YUV_REF_CHROMA_H_BIAS) >>
				(YUV_REF_SHIFT - 5)
		v_out[c] =
			(YUV_REF_RV * r + YUV_REF_GV * g + YUV_REF_BV * b + 256 * YUV_REF_ONE + YUV_REF_CHROMA_H_BIAS) >>
				(YUV_REF_SHIFT - 5)
	}
}

// Full-frame RGBA -> NV12 into swscale's own memory layout: plane 0 is w*h
// luma bytes at `y_stride`; the chroma plane follows at y_stride*h and holds
// w/2 U bytes then w/2 V bytes per row, h/2 rows, at `uv_stride`.
//
// `scratch_u` / `scratch_v` are caller-owned h*i32 buffers, one per luma row.
yuv_ref_rgba_to_nv12 :: proc(
	rgba: []u8,
	w, h: int,
	y_stride, uv_stride: int,
	yuv: []u8,
	scratch_u, scratch_v: []i32,
) {
	uv_w := w / YUV_REF_CHROMA_H_TAPS
	for y in 0 ..< h {
		row := rgba[y * w * 4:]
		for x in 0 ..< w {
			p := row[x * 4:]
			yuv[y * y_stride + x] = yuv_ref_clip8(
				(
					YUV_REF_RY * i32(p[0]) +
					YUV_REF_GY * i32(p[1]) +
					YUV_REF_BY * i32(p[2]) +
					YUV_REF_LUMA_BIAS
				) >> YUV_REF_SHIFT,
			)
		}
		yuv_ref_chroma_row(row, w, scratch_u[y * uv_w:], scratch_v[y * uv_w:])
	}
	uv_plane := yuv[y_stride * h:]
	for k in 0 ..< h / 2 {
		r0 := yuv_ref_clamp_row(2 * k - 1, h)
		r1 := yuv_ref_clamp_row(2 * k, h)
		r2 := yuv_ref_clamp_row(2 * k + 1, h)
		r3 := yuv_ref_clamp_row(2 * k + 2, h)
		a0 := scratch_u[r0 * uv_w:]
		a1 := scratch_u[r1 * uv_w:]
		a2 := scratch_u[r2 * uv_w:]
		a3 := scratch_u[r3 * uv_w:]
		b0 := scratch_v[r0 * uv_w:]
		b1 := scratch_v[r1 * uv_w:]
		b2 := scratch_v[r2 * uv_w:]
		b3 := scratch_v[r3 * uv_w:]
		dst := uv_plane[k * uv_stride:]
		for c in 0 ..< uv_w {
			u := YUV_REF_CHROMA_V_C0 * a0[c] + YUV_REF_CHROMA_V_C1 * a1[c] +
				YUV_REF_CHROMA_V_C2 * a2[c] + YUV_REF_CHROMA_V_C3 * a3[c]
			v := YUV_REF_CHROMA_V_C0 * b0[c] + YUV_REF_CHROMA_V_C1 * b1[c] +
				YUV_REF_CHROMA_V_C2 * b2[c] + YUV_REF_CHROMA_V_C3 * b3[c]
			dst[c * 2 + 0] = yuv_ref_clip8(u >> YUV_REF_CHROMA_OUT_SHIFT)
			dst[c * 2 + 1] = yuv_ref_clip8(v >> YUV_REF_CHROMA_OUT_SHIFT)
		}
	}
}
