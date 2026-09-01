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

// render_text_clip_into_buffer rasterizes `title` as white glyphs at the top of
// an RGBA buffer bw x bh. Background is fully transparent so the text composites
// over the canvas/video via the preview pipeline's alpha blending. It returns
// the tight text rect (ox, oy, w, h) in buffer pixels — the ink's top-left origin
// and its extent — so the caller can sample exactly that region and size the
// clip's bounding box to the text rather than the whole buffer.
render_text_clip_into_buffer :: proc(title: string, buf: []u8, bw, bh: int) -> (ox: int, oy: int, ow: int, oh: int) {
	mem.zero(raw_data(buf), len(buf))
	if len(title) == 0 {
		return 0, 0, 0, 0
	}
	if !text_clip_font_init {
		stb.InitFont(&text_clip_font, raw_data(font_data), 0)
		text_clip_font_init = true
	}
	scale := stb.ScaleForPixelHeight(&text_clip_font, f32(TEXT_CLIP_FONT_PIXELS))
	ascent, descent, linegap: c.int
	stb.GetFontVMetrics(&text_clip_font, &ascent, &descent, &linegap)
	baseline := f32(ascent) * scale
	top := max(int)
	bottom := -max(int)
	left := max(int)
	right := -max(int)
	x_pen: f32 = 4.0
	prev: rune = 0
	for ch in title {
		if prev > 0 {
			x_pen += f32(stb.GetCodepointKernAdvance(&text_clip_font, prev, ch)) * scale
		}
		adv: c.int
		stb.GetCodepointHMetrics(&text_clip_font, ch, &adv, nil)
		box_val: [4]c.int
		stb.GetCodepointBitmapBox(&text_clip_font, ch, scale, scale, &box_val[0], &box_val[1], &box_val[2], &box_val[3])
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
			if n <= len(text_clip_scratch) {
				mem.zero(raw_data(text_clip_scratch[:n]), n)
				stb.MakeCodepointBitmap(&text_clip_font, raw_data(text_clip_scratch[:]), c.int(gw), c.int(gh), c.int(gw), scale, scale, ch)
				for gy in 0 ..< gh {
					for gx in 0 ..< gw {
						a := int(text_clip_scratch[gy * gw + gx])
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
