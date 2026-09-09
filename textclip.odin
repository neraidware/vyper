package main

import "core:c"
import "core:mem"
import stb "vendor:stb/truetype"

// ---------------------------------------------------------------------------
// Text clip rendering: rasterize a clip's title into the CPU RGBA preview
// buffer (the same buffer a video clip's decoded frame fills) so the slot can
// be uploaded and drawn through the normal preview pipeline. White glyphs on a
// transparent background, positioned at the top-left of the preview buffer.
// ---------------------------------------------------------------------------

text_clip_font:      stb.fontinfo
text_clip_font_init: bool

TEXT_CLIP_FONT_PIXELS :: 48

// Scratch for one glyph's bitmap; sized for a 48px monospace glyph (a few KB).
// Preview rendering is single-threaded on the UI loop, so a shared buffer is
// safe here and avoids a per-codepoint dynamic allocation.
text_clip_scratch: [8192]u8

// text_clip_hash is a cheap FNV-1a over the title, used to detect when a text
// clip's rendered buffer is stale (its name changed) without storing a string.
text_clip_hash :: proc(s: string) -> u64 {
	h: u64 = 14695981039346656037
	for i in 0 ..< len(s) {
		h = (h ~ u64(s[i])) * 1099511628211
	}
	return h
}

// text_scratch_size_for returns a safe byte size for the per-glyph bitmap
// scratch at a given glyph pixel height (a single codepoint bitmap can be up to
// ~font_px x font_px, so the scratch must grow with the baked font).
text_scratch_size_for :: proc(font_px: f32) -> int {
	fp := int(font_px) + 1
	return fp * fp + 4096
}

// text_buf_size_for estimates a tight RGBA buffer (bw x bh) large enough to
// hold a title rasterized at the given glyph pixel height without clipping.
// Generous estimate: ~1.2*font_px advance per codepoint, ~2.4*font_px tall.
text_buf_size_for :: proc(title: string, font_px: f32) -> (bw: int, bh: int) {
	fp := f32(1)
	if font_px > 0 {
		fp = font_px
	}
	bw = int(f32(len(title) + 1) * fp * 1.2) + 8
	bh = int(fp * 2.4) + 8
	return bw, bh
}

// rasterize_title_into_buffer is the shared core: rasterize `title` as white
// glyphs at the top of an RGBA buffer bw x bh on a fully transparent background.
// font_px is the glyph pixel height (TEXT_CLIP_FONT_PIXELS at scale 1) — callers
// pass 48*clip.scale so baking the clip's scale into the raster keeps glyphs
// crisp instead of upscaling a fixed-size render. Returns the tight ink rect
// (ox, oy, w, h) in buffer pixels. Font state and the per-glyph scratch are
// passed in so each caller owns them — the UI thread and the render worker each
// keep their own, avoiding a data race on the shared preview font/scratch
// globals.
rasterize_title_into_buffer :: proc(
	title: string,
	buf: []u8, bw, bh: int,
	font: ^stb.fontinfo,
	font_init: ^bool,
	scratch: []u8,
	font_px: f32,
) -> (ox: int, oy: int, ow: int, oh: int) {
	mem.zero(raw_data(buf), len(buf))
	if len(title) == 0 {
		return 0, 0, 0, 0
	}
	px := font_px
	if px <= 0 {
		px = TEXT_CLIP_FONT_PIXELS
	}
	if !font_init^ {
		stb.InitFont(font, raw_data(font_data), 0)
		font_init^ = true
	}
	scale := stb.ScaleForPixelHeight(font, px)
	ascent, descent, linegap: c.int
	stb.GetFontVMetrics(font, &ascent, &descent, &linegap)
	baseline := f32(ascent) * scale
	top := max(int)
	bottom := -max(int)
	left := max(int)
	right := -max(int)
	x_pen: f32 = 4.0
	prev: rune = 0
	for ch in title {
		if prev > 0 {
			x_pen += f32(stb.GetCodepointKernAdvance(font, prev, ch)) * scale
		}
		adv: c.int
		stb.GetCodepointHMetrics(font, ch, &adv, nil)
		box_val: [4]c.int
		stb.GetCodepointBitmapBox(font, ch, scale, scale, &box_val[0], &box_val[1], &box_val[2], &box_val[3])
		ix0 := int(box_val[0])
		iy0 := int(box_val[1])
		ix1 := int(box_val[2])
		iy1 := int(box_val[3])
		gw := int(ix1 - ix0)
		gh := int(iy1 - iy0)
		start_x := cast(int)x_pen + ix0
		start_y := cast(int)baseline + iy0
		// Track the drawn ink so the returned rect is the tight text bounds.
		x0 := start_x
		x1 := start_x + gw
		y0 := start_y
		y1 := start_y + gh
		if y0 < top {
			top = y0
		}
		if y1 > bottom {
			bottom = y1
		}
		if x0 < left {
			left = x0
		}
		if x1 > right {
			right = x1
		}
		if gw > 0 && gh > 0 {
			n := gw * gh
			if n <= len(scratch) {
				mem.zero(raw_data(scratch[:n]), n)
				stb.MakeCodepointBitmap(font, raw_data(scratch[:]), c.int(gw), c.int(gh), c.int(gw), scale, scale, ch)
				for gy in 0 ..< gh {
					for gx in 0 ..< gw {
						a := int(scratch[gy * gw + gx])
						if a == 0 {
							continue
						}
						px := start_x + gx
						py := start_y + gy
						if px < 0 || py < 0 || px >= bw || py >= bh {
							continue
						}
						o := (py * bw + px) * 4
						buf[o + 0] = 255
						buf[o + 1] = 255
						buf[o + 2] = 255
						buf[o + 3] = u8(a)
					}
				}
			}
		}
		x_pen += f32(adv) * scale
		prev = ch
	}
	ow = max(0, right - left)
	oh = max(0, bottom - top)
	return left, top, ow, oh
}

// text_buf_size_for_lines estimates a single-call RGBA buffer (bw x bh) large
// enough to hold the stacked lines of a multi-line subtitle rasterized at the
// given glyph pixel height. Line pitch is ~1.2*font_px; the estimate is the
// widest line estimate wide and the line count tall (with cap padding).
text_buf_size_for_lines :: proc(lines: []string, font_px: f32) -> (bw: int, bh: int) {
	fp := f32(1)
	if font_px > 0 {
		fp = font_px
	}
	pitch := int(fp * 1.2)
	width, _ := text_buf_size_for("", font_px)
	for l in lines {
		w, _ := text_buf_size_for(l, font_px)
		if w > width {
			width = w
		}
	}
	return width, 8 + len(lines) * pitch + int(fp * 1.2)
}

// rasterize_lines_into_buffer rasterizes `lines` (each as a single-line title
// by calling rasterize_title_into_buffer) stacked top-to-bottom, each line
// horizontally centered relative to the OTHER lines' ink, into a single RGBA
// buffer bw x bh. Returns the tight ink rect (ox, oy, w, h) in buffer pixels.
// Same signature contract as rasterize_title_into_buffer (thread-local font,
// font_init, scratch).
rasterize_lines_into_buffer :: proc(
	lines: []string,
	buf: []u8, bw, bh: int,
	font: ^stb.fontinfo,
	font_init: ^bool,
	scratch: []u8,
	font_px: f32,
	allocator: mem.Allocator,
) -> (ox: int, oy: int, ow: int, oh: int) {
	mem.zero(raw_data(buf), len(buf))
	if len(lines) == 0 {
		return 0, 0, 0, 0
	}
	px := font_px
	if px <= 0 {
		px = TEXT_CLIP_FONT_PIXELS
	}
	if !font_init^ {
		stb.InitFont(font, raw_data(font_data), 0)
		font_init^ = true
	}

	// Per-line rasterize into `allocator`-backed scratch first: every line is
	// measured/positioned before compositing because centering needs the widest
	// line's ink width. Callers pass the frame temp arena (UI thread) or the
	// job arena (render worker) — line buffers never outlive the call.
	Type_Line_Slot :: struct {
		buf: []u8,
		bw:  int,
		bh:  int,
		lox: int,
		loy: int,
		low: int,
		loh: int,
	}
	slots := make([]Type_Line_Slot, len(lines), context.temp_allocator)

	pitch := int(px * 1.2)
	max_ink_w := 0
	ink_top := max(int)
	ink_bottom := -max(int)

	for i in 0 ..< len(lines) {
		lbw, lbh := text_buf_size_for(lines[i], px)
		lbuf := make([]u8, lbw * lbh * 4, allocator)
		lox, loy, low, loh := rasterize_title_into_buffer(lines[i], lbuf, lbw, lbh, font, font_init, scratch, px)
		slots[i] = {buf = lbuf, bw = lbw, bh = lbh, lox = lox, loy = loy, low = low, loh = loh}
		if low > max_ink_w {
			max_ink_w = low
		}
		if low == 0 {
			continue
		}
		band_y := 4 + i * pitch
		if band_y + loy < ink_top {
			ink_top = band_y + loy
		}
		if band_y + loy + loh > ink_bottom {
			ink_bottom = band_y + loy + loh
		}
	}

	if max_ink_w == 0 {
		return 0, 0, 0, 0
	}

	// Re-position lines horizontally (band origin = (max_ink_w - ink_w)/2) and
	// copy glyph pixels. main row = band_top + loy + dy.
	left_ink := max(int)
	right_ink := -max(int)
	for i in 0 ..< len(lines) {
		s := slots[i]
		if s.low == 0 {
			continue
		}
		band_top := 4 + i * pitch
		band_dx := (max_ink_w - s.low) / 2
		dst_y0 := band_top + s.loy
		if band_dx < left_ink {
			left_ink = band_dx
		}
		if band_dx + s.low > right_ink {
			right_ink = band_dx + s.low
		}
		for dy in 0 ..< s.loh {
			mrow := dst_y0 + dy
			if mrow < 0 || mrow >= bh {
				continue
			}
			srow := s.loy + dy
			for dx0 in 0 ..< s.low {
				sx := s.lox + dx0
				dx := band_dx + dx0
				if dx < 0 || dx >= bw {
					continue
				}
				a := u8(s.buf[(srow * s.bw + sx) * 4 + 3])
				if a == 0 {
					continue
				}
				o := (mrow * bw + dx) * 4
				buf[o + 0] = 255
				buf[o + 1] = 255
				buf[o + 2] = 255
				buf[o + 3] = a
			}
		}
	}

	ow = max(0, right_ink - left_ink)
	oh = max(0, ink_bottom - ink_top)
	return left_ink, ink_top, ow, oh
}
