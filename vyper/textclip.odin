package vyper

import "core:c"
import "core:mem"
import stb "vendor:stb/truetype"

// ---------------------------------------------------------------------------
// Text clip rendering: rasterize a clip's title into the CPU RGBA preview
// buffer (the same buffer a video clip's decoded frame fills) so the slot can
// be uploaded and drawn through the normal preview pipeline. White glyphs on a
// transparent background, positioned at the top-left of the preview buffer.
// ---------------------------------------------------------------------------

// Text_Clip_State is the text-clip rasterizer's shared font state: the baked
// monospace face and an init flag (stb.InitFont runs once, lazily). Callers pass
// their own per-glyph bitmap scratch (text_rasterize/line_rasterize take one) so
// the preview loop and render worker never share a buffer.
Text_Clip_State :: struct {
	font:      stb.fontinfo,
	font_init: bool,
}
text_clip_state: Text_Clip_State

TEXT_CLIP_FONT_PIXELS :: 48

// TEXT_REBAKE_EPS: how far a clip's scale may drift, in baked font pixels,
// before its raster is discarded and re-rasterized.
//
// Comparing floats exactly re-bakes on sub-ULP wobble — an eased curve's
// rounding — which under an animated scale is a rasterize per frame for a
// difference no glyph can express. A tolerance too loose leaves the raster
// coarser than the scale asks for. A tenth of a pixel of font height sits below
// what a glyph raster can express at any size, so it costs nothing visually and
// stops the churn.
//
// Shared by both sinks, which is the point: the preview compared
// `slot.text_font_px != font_px` EXACTLY while the export used a tolerance, so
// the same clip could re-rasterize on one side and not the other. Scale is baked
// into a text raster's resolution rather than applied at blit time, so both
// sides answer "is this ink still the right size" and must answer it the same
// way.
TEXT_REBAKE_EPS :: 0.1

// text_font_px_for is the baked font size for a clip's SAMPLED scale — the
// resolution its raster is drawn at. Both sinks rasterize at this and compare
// against the size they last baked, so "what font does this scale ask for" has
// one answer rather than one per sink.
text_font_px_for :: proc(scale: f32) -> f32 {
	return f32(TEXT_CLIP_FONT_PIXELS) * scale
}

// text_font_needs_rebake reports whether a raster baked at `baked_font_px` no
// longer matches the font size `scale` asks for.
text_font_needs_rebake :: proc(baked_font_px, scale: f32) -> bool {
	return abs(baked_font_px - text_font_px_for(scale)) > TEXT_REBAKE_EPS
}

// TEXT_BOX_PAD is the small air margin above the first line's ascenders and
// below the last line's descenders kept inside a text/subtitle box, so the
// antialias overshoot never kisses the box edge. It is the ONLY vertical
// padding a text box carries: the box height itself comes from the font's
// typographic line metrics (text_metrics_px), which are the standard per-font
// character height and can't balloon like the old fixed galley estimates.
TEXT_BOX_PAD :: 2

// text_metrics_px reports the font's typographic line box at glyph height
// `px`: ascent_px pixels above the baseline, and the full line_h = ascent +
// descent. Sizing a text box off these (rather than this title's ink) gives a
// box that is a CONSTANT per font+size and automatically leaves room for
// ensure_text_font initializes `font` from the process-wide font data exactly
// once. All three raster paths (metrics, rasterize, and the title blit) share
// this rather than repeating the lazy init, because the invariant it protects
// is the same in all three and a site that forgets it is a segfault: with no
// data loaded, stbtt_InitFont dereferences a nil buffer and reads out of
// bounds, and the crash names neither stb nor fonts. font_state.data is filled
// once at startup by load_font_data, so any headless path that renders text
// before that (the export test) must load it first.
ensure_text_font :: proc(font: ^stb.fontinfo, font_init: ^bool) {
	if font_init^ {
		return
	}
	assert(
		len(font_state.data) > 0,
		"ensure_text_font: font data not loaded (call load_font_data before rendering text)",
	)
	stb.InitFont(font, raw_data(font_state.data), 0)
	font_init^ = true
}

// descenders -- no jump when the deepest glyph in a string changes, no dead
// margin when a string has no descenders.
text_metrics_px :: proc(
	font: ^stb.fontinfo,
	font_init: ^bool,
	px: f32,
) -> (
	ascent_px, line_h: int,
) {
	epx := px
	if epx <= 0 {
		epx = TEXT_CLIP_FONT_PIXELS
	}
	ensure_text_font(font, font_init)
	scale := stb.ScaleForPixelHeight(font, epx)
	ascent, descent, _: c.int
	stb.GetFontVMetrics(font, &ascent, &descent, nil)
	a := int(f32(ascent) * scale)
	d := int(f32(-descent) * scale) // descent is negative (below baseline)
	return a, a + d
}

// Callers pass their per-glyph bitmap scratch to text_rasterize / the line
// rasterizers; sized for a 48px monospace glyph (a few KB), though bounding via
// text_scratch_size_for. Preview rendering is single-threaded on the UI loop,
// so each caller's shared buffer is safe and avoids a per-codepoint dynamic
// allocation.

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

// text_buf_ensure returns `*buf` grown to at least `need` bytes, reusing whatever
// is already allocated, and returns it ready to use.
//
// Grow-only, never shrink. This is the hot path for every text clip and every
// subtitle cue, so reallocating per call is exactly the per-frame allocation the
// ownership rules forbid. It is ALSO what makes the four raster sites
// interchangeable: the export worker and each preview slot each keep their own
// buffer (the UI thread and the worker must not share one -- that would be a
// data race), so the BUFFER differs per owner while the POLICY is identical.
// Copy-pasted, it was four length checks that each recomputed the size twice and
// could drift apart.
//
// The `delete` below is immediately followed by the assignment, and that
// ordering is load-bearing rather than incidental. Odin's `delete` is a free,
// not a destructor: the runtime's delete_slice only calls mem_free_with_size and
// leaves the slice HEADER ALONE, so afterwards `buf^` still carries the old
// length and a dangling pointer. Any read of `len(buf^)` in that window sees
// stale data and would skip a needed grow. Zeroing first (the `= {}` some of
// these sites used to do) papers over the window instead of closing it, which is
// why it is not here: the check happens BEFORE the delete and the return reads
// the freshly assigned header, so there is no window at all.
text_buf_ensure :: proc(buf: ^[]u8, need: int) -> []u8 {
	if len(buf^) < need {
		delete(buf^)
		buf^ = make([]u8, need)
	}
	return buf^
}

// text_buf_size_for estimates a tight RGBA buffer (bw x bh) large enough to
// hold a title rasterized at the given glyph pixel height without clipping.
// Width is a generous advance estimate (1.2*font_px per codepoint); height is
// the font's typographic line box (ascent + descent + TEXT_BOX_PAD air), so
// the raster's baseline sits inside it and descenders always fit.
text_buf_size_for :: proc(
	title: string,
	font: ^stb.fontinfo,
	font_init: ^bool,
	font_px: f32,
) -> (
	bw: int,
	bh: int,
) {
	fp := f32(1)
	if font_px > 0 {
		fp = font_px
	}
	bw = int(f32(len(title) + 1) * fp * 1.2) + 8
	_, lh := text_metrics_px(font, font_init, font_px)
	bh = TEXT_BOX_PAD + lh + TEXT_BOX_PAD
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
	buf: []u8,
	bw, bh: int,
	font: ^stb.fontinfo,
	font_init: ^bool,
	scratch: []u8,
	font_px: f32,
) -> (
	ox: int,
	oy: int,
	ow: int,
	oh: int,
) {
	mem.zero(raw_data(buf), len(buf))
	if len(title) == 0 {
		return 0, 0, 0, 0
	}
	px := font_px
	if px <= 0 {
		px = TEXT_CLIP_FONT_PIXELS
	}
	ensure_text_font(font, font_init)
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
		stb.GetCodepointBitmapBox(
			font,
			ch,
			scale,
			scale,
			&box_val[0],
			&box_val[1],
			&box_val[2],
			&box_val[3],
		)
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
				stb.MakeCodepointBitmap(
					font,
					raw_data(scratch[:]),
					c.int(gw),
					c.int(gh),
					c.int(gw),
					scale,
					scale,
					ch,
				)
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
// given glyph pixel height. Width is the widest line's estimate; height is
// per-line typographic line boxes stacked (TEXT_BOX_PAD air top and bottom, no
// dead tail -- each line's box already includes its descent space).
text_buf_size_for_lines :: proc(
	lines: []string,
	font: ^stb.fontinfo,
	font_init: ^bool,
	font_px: f32,
) -> (
	bw: int,
	bh: int,
) {
	_, lh := text_metrics_px(font, font_init, font_px)
	width := 0
	for l in lines {
		w, _ := text_buf_size_for(l, font, font_init, font_px)
		if w > width {
			width = w
		}
	}
	return width, TEXT_BOX_PAD + len(lines) * lh + TEXT_BOX_PAD
}

// rasterize_lines_into_buffer rasterizes `lines` (each as a single-line title
// by calling rasterize_title_into_buffer) stacked top-to-bottom, each line
// horizontally centered relative to the OTHER lines' ink, into a single RGBA
// buffer bw x bh. Returns the tight ink rect (ox, oy, w, h) in buffer pixels.
// Same signature contract as rasterize_title_into_buffer (thread-local font,
// font_init, scratch).
rasterize_lines_into_buffer :: proc(
	lines: []string,
	buf: []u8,
	bw, bh: int,
	font: ^stb.fontinfo,
	font_init: ^bool,
	scratch: []u8,
	font_px: f32,
	allocator: mem.Allocator,
) -> (
	ox: int,
	oy: int,
	ow: int,
	oh: int,
) {
	mem.zero(raw_data(buf), len(buf))
	if len(lines) == 0 {
		return 0, 0, 0, 0
	}
	px := font_px
	if px <= 0 {
		px = TEXT_CLIP_FONT_PIXELS
	}
	ensure_text_font(font, font_init)

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

	// Line pitch = the font's typographic line box, so stacked lines sit at
	// exactly their standard character height (no overlap, no dead gap).
	_, lh := text_metrics_px(font, font_init, px)
	pitch := lh
	max_ink_w := 0
	ink_top := max(int)
	ink_bottom := -max(int)

	for i in 0 ..< len(lines) {
		lbw, lbh := text_buf_size_for(lines[i], font, font_init, px)
		lbuf := make([]u8, lbw * lbh * 4, allocator)
		lox, loy, low, loh := rasterize_title_into_buffer(
			lines[i],
			lbuf,
			lbw,
			lbh,
			font,
			font_init,
			scratch,
			px,
		)
		slots[i] = {
			buf = lbuf,
			bw  = lbw,
			bh  = lbh,
			lox = lox,
			loy = loy,
			low = low,
			loh = loh,
		}
		if low > max_ink_w {
			max_ink_w = low
		}
		if low == 0 {
			continue
		}
		band_y := TEXT_BOX_PAD + i * pitch
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
		band_top := TEXT_BOX_PAD + i * pitch
		band_dx := (max_ink_w - s.low) / 2
		dst_y0 := band_top + s.loy
		if band_dx < left_ink {
			left_ink = band_dx
		}
		if band_dx + s.low > right_ink {
			right_ink = band_dx + s.low
		}
		for dy in 0 ..< s.loh {
			// The rasterizer's ink rect (lox,loy,low,loh) may extend left/above
			// its own galley when glyph bearings overshoot the buffer, so the
			// source reads must be clamped like the output writes above.
			srow := s.loy + dy
			if srow < 0 || srow >= s.bh {
				continue
			}
			mrow := dst_y0 + dy
			if mrow < 0 || mrow >= bh {
				continue
			}
			for dx0 in 0 ..< s.low {
				sx := s.lox + dx0
				if sx < 0 || sx >= s.bw {
					continue
				}
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
