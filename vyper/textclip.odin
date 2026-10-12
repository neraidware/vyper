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

// --- layout -----------------------------------------------------------------
//
// TEXT_CHAR_UNIT is what Text_Glyph.char_index counts. It is a codepoint index
// today, and it is named so that changing it is a change to ONE definition
// rather than to the layout, the painter and every piece that addresses a
// character.
//
// The unit that will eventually replace it is a Unicode grapheme cluster, and
// kb_text_shape already vendors both the segmentation and the OpenType shaping
// for it (in the Odin distribution's vendor tree). Two things about that are
// worth knowing before adopting it, because both bear on this axis:
//
//   - Segmentation is SEPARABLE from shaping. `kbts_BreakEntireStringUtf8`
//     returns grapheme boundaries over a UTF-8 string with no font and no
//     shaping context, so the cluster axis does not require adopting OpenType
//     shaping to exist.
//   - The shaper's glyph cluster is OUR choice: ShapeCodepointWithUserId with
//     user_id_generation_mode.SOURCE_INDEX carries whichever index we hand in,
//     so a codepoint axis today becomes a grapheme axis later by changing what
//     we pass, not by reworking the layout.
//
// It does not link yet: the bindings want a prebuilt `lib/kb_text_shape.a` from
// `src/build_unix.sh`, which is a build-system change (and the Windows CI has no
// such script). Until then a codepoint index is the honest unit, with the
// combining-mark case it implies flagged rather than hidden: a reveal range
// stored in codepoints can split a cluster.

// Text_Reveal is which characters of a laid-out text get DRAWN, as a half-open
// range over Text_Glyph.char_index. It is the typing animation: first=0 with a
// rising last walks the string out; first rising with last pinned eats it from
// the end; both together are a window.
//
// It lives on the TEXT, not on a piece, because "how much of this string is
// visible" is one question about one string. When pieces arrive they may
// override it per piece -- a word typed on its own -- but a piece that does not
// override inherits this, so "type the whole text" is one range and no
// per-piece data at all. Giving every piece its own copy instead would mean N
// copies of one animated value that can drift apart.
//
// A range rather than a character COUNT on purpose: a count reads the same
// whether a character is one codepoint or one grapheme cluster, so this survives
// the segmenter changing under it. See TEXT_CHAR_UNIT.
Text_Reveal :: struct {
	first: int,
	last:  int,
}

// clip_pieces_ink is the whole compositor pass for a text clip: build the graph
// from the clip's pieces, evaluate it into `inks`, and hand the painter its
// answer. One call, because the two halves are a unit -- a graph nobody evaluates
// is a graph that silently paints nothing.
//
// Returns `inks` unchanged when the pieces are malformed, which is a caller bug
// and not a user error: the text then paints with whatever the table already
// holds, which is the same thing it did before the pieces were consulted.
// The ink table is sized HERE rather than by the caller. Every caller held an
// empty dynamic array on its first bake, so a caller-sized table silently
// evaluated zero characters and the clip painted nothing -- which is how the
// zorder gate caught it: it is the only gate that composites real text over real
// video and measures that the difference exists.
text_pieces_ink :: proc(
	pieces: Text_Pieces_Range,
	character_count: int,
	inks: ^[dynamic]Text_Ink,
	order: ^[dynamic]int,
) -> []Text_Ink {
	// A clip with no pieces is the design note's fast path -- a plain text clip is
	// not a graph -- but it still goes through one, a single whole-text style
	// process. That keeps "who draws this character" answerable by exactly one
	// thing for every clip: the graph. A separate default here would be a second
	// answer for the same question, which is how a gap starts being drawn by one
	// path and not the other.
	whole_text := pieces
	// len(), NOT `== nil`: a zero range views as rows[0:0], which is a valid
	// non-nil slice, so the nil test said "this clip HAS pieces" and skipped the
	// implicit one. Every plain text clip then painted nothing -- which is exactly
	// what the zorder probe caught, since it is the one gate that composites real
	// text over real video and measures the difference.
	if len(session_piece_view(pieces)) == 0 {
		whole_text = Text_Pieces_Range{}
		session_piece_push(
			&whole_text,
			Text_Piece {
				start = 0,
				len = character_count,
				reveal = text_reveal_all(character_count),
				color = TEXT_INK_DEFAULT_RGB,
			},
		)
		defer session_piece_release(whole_text)
	}
	if len(inks^) < character_count {
		resize(inks, character_count)
	}
	graph := Node_Graph{}
	if !text_graph_build(&graph, character_count, whole_text) {
		text_graph_free(&graph)
		return inks[:]
	}
	graph_eval_text(&graph, character_count, inks[:], order)
	text_graph_free(&graph)
	return inks[:]
}

// clip_pieces_ink is the UI-thread entry: the clip knows its own title length, so
// callers holding a clip do not have to work it out to ask the same question.
clip_pieces_ink :: proc(clip: ^Clip, inks: ^[dynamic]Text_Ink, order: ^[dynamic]int) -> []Text_Ink {
	return text_pieces_ink(clip.pieces, len(clip_name(clip)), inks, order)
}

// text_clip_ink is the painter's question, and the compositor answers it.
//
// The rasterizer does not know that a piece, a node or a colour exists: it asks
// what ink a character has and writes what it is told. That is what keeps this
// loop from growing a case per property -- colour, stroke, font and everything
// after them are nodes in text_graph_build, not branches here.
//
// The answer is resolved for the WHOLE text once per bake, by graph_eval_text,
// rather than walked per character: processes annotate, the renderer emits, and
// the paint loop only draws. A clip with no pieces is the design note's fast
// path -- it is not a graph at all, and its answer is the default ink for every
// character.
text_clip_ink :: proc(inks: []Text_Ink, char_index: int) -> Text_Ink {
	if char_index < 0 || char_index >= len(inks) {
		return {}
	}
	return inks[char_index]
}

// text_reveal_all is the "draw everything" range. It is deliberately not a
// sentinel the painter compares against: the painter clamps, so an unset reveal
// has to BE the full range, not a magic negative that means the same thing.
text_reveal_all :: proc(character_count: int) -> Text_Reveal {
	return Text_Reveal{first = 0, last = character_count}
}

// text_reveal_contains is the whole test a painter needs: is this character
// inside the revealed window? Written once so the clamping rule lives once.
text_reveal_contains :: proc(reveal: Text_Reveal, char_index: int) -> bool {
	return char_index >= reveal.first && char_index < reveal.last
}

// Text_Glyph is one character's placement, as measured rather than painted.
//
// It is the data the old loop computed and threw away on every iteration. With
// it kept, everything a per-character feature needs — a stroke pass, a colour
// per character, a reveal range over "characters 3..7 of this piece" — is a read
// of this array instead of a rewrite of the rasterizer.
Text_Glyph :: struct {
	codepoint:  rune,
	// char_index: this character's position in the text, per TEXT_CHAR_UNIT.
	// Carried so a glyph can be traced back to the piece that owns it and to
	// its offset inside that piece.
	char_index: int,
	// x: the pen position when this glyph starts, in raster pixels. advance: how
	// far the pen moves after it, kerning already applied to x. box: stb's
	// integer bitmap box at the baked scale, which is what MakeCodepointBitmap
	// and the ink rect are derived from.
	x:       f32,
	advance: f32,
	box:     [4]c.int,
}

// Text_Layout is one line's worth of measurement. glyphs BORROWS the caller's
// buffer: the layout writes into storage the caller owns and reuses, so laying
// text out allocates nothing after the first line of a given length.
Text_Layout :: struct {
	glyphs:   []Text_Glyph,
	scale:    f32,
	baseline: f32,
	// width: the exact advance width of the laid text, kerning included. The
	// buffer sizer used to GUESS this at 1.2 pixels per codepoint; it can read
	// the real number here instead, which is the one thing this split buys that
	// is free today.
	width: f32,
	// ink: the tight bounds of the WHOLE laid text, in raster pixels, with the same
	// arithmetic the painter used inline — a glyph with no ink (a space) still
	// advances the right edge, exactly as before.
	//
	// This is the full extent, which is NOT what the painter returns: that one is
	// the revealed ink. Both are wanted, and they are different questions — a clip's
	// box stays the full text's (so a line being typed does not shift its centering),
	// while the blit only samples what is visible. Centering a text clip reads this.
	ink_x, ink_y, ink_w, ink_h: int,
}

// text_layout_into measures `title` into `glyphs`, which the caller owns and
// reuses: it is cleared (keeping its capacity) and refilled. Font state is passed
// in so each caller keeps its own, the same reason the rasterizer takes it.
//
// Nothing here paints. That is the whole point of the split: measurement is
// cheap, has no output buffer, and every per-character feature is a consumer of
// it, so the expensive half runs only when something asks for pixels.
text_layout_into :: proc(
	title: string,
	font: ^stb.fontinfo,
	font_init: ^bool,
	font_px: f32,
	glyphs: ^[dynamic]Text_Glyph,
) -> (
	layout: Text_Layout,
) {
	clear(glyphs)
	if len(title) == 0 {
		return {}
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
	char_index := 0
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
		append(
			glyphs,
			Text_Glyph {
				codepoint = ch,
				char_index = char_index,
				x = x_pen,
				advance = f32(adv) * scale,
				box = box_val,
			},
		)
		char_index += 1
		// The ink rect is measured HERE rather than while painting, and with the
		// same arithmetic: a glyph with no ink still advances the right edge, so
		// the rect is identical to what the fused loop produced.
		start_x := cast(int)x_pen + int(box_val[0])
		start_y := cast(int)baseline + int(box_val[1])
		ink_right := start_x + int(box_val[2]) - int(box_val[0])
		ink_bottom := start_y + int(box_val[3]) - int(box_val[1])
		if start_y < top {
			top = start_y
		}
		if ink_bottom > bottom {
			bottom = ink_bottom
		}
		if start_x < left {
			left = start_x
		}
		if ink_right > right {
			right = ink_right
		}
		x_pen += f32(adv) * scale
		prev = ch
	}
	layout = Text_Layout {
		glyphs = glyphs[:],
		scale = scale,
		baseline = baseline,
		width = x_pen,
		ink_x = left,
		ink_y = top,
		ink_w = max(0, right - left),
		ink_h = max(0, bottom - top),
	}
	return
}

// rasterize_title_into_buffer paints a measured layout as white glyphs at the top
// of an RGBA buffer bw x bh on a fully transparent background. It is the
// measurement's other half: the loop it used to fuse is now text_layout_into, and
// what is left here is one glyph bitmap per entry.
//
// `layout_glyphs` is the caller-owned buffer text_layout_into writes into, for the
// same reason the per-glyph `scratch` is passed in: the UI thread and the render
// worker each keep their own, so neither races the other.
//
// `inks` is the per-character ink the compositor resolved before this call. The
// text is still LAID OUT whole — the kerning and advance of a hidden character
// affect the ones after it, so a partially typed line does not reflow as it
// types — and only the glyphs no piece claims are skipped at paint time. The
// returned ink rect is therefore the INKED rect, not the text's full extent,
// which is what a caller blits.
rasterize_title_into_buffer :: proc(
	title: string,
	buf: []u8,
	bw, bh: int,
	font: ^stb.fontinfo,
	font_init: ^bool,
	scratch: []u8,
	layout_glyphs: ^[dynamic]Text_Glyph,
	inks: []Text_Ink,
	font_px: f32,
) -> (
	ox: int,
	oy: int,
	ow: int,
	oh: int,
) {
	mem.zero(raw_data(buf), len(buf))
	layout := text_layout_into(title, font, font_init, font_px, layout_glyphs)
	baseline_i := cast(int)layout.baseline
	// The ink rect starts as EMPTY and is measured from the glyphs actually drawn,
	// so a half-revealed text reports the width of what is visible. Measuring it in
	// text_layout_into instead would report the full string and blit dead space.
	top := max(int)
	bottom := -max(int)
	left := max(int)
	right := -max(int)
	for glyph in layout.glyphs {
		ink := text_clip_ink(inks, glyph.char_index)
		if !ink.drawn {
			continue
		}
		start_x := cast(int)glyph.x + int(glyph.box[0])
		start_y := baseline_i + int(glyph.box[1])
		gw := int(glyph.box[2]) - int(glyph.box[0])
		gh := int(glyph.box[3]) - int(glyph.box[1])
		// Tracked BEFORE the no-ink skip, and for the same reason the layout did:
		// a glyph with no ink (a space) still advances the right edge, so the inked
		// rect of a revealed trailing space is the pen position, not the last ink.
		ink_right := start_x + gw
		ink_bottom := start_y + gh
		if start_y < top {
			top = start_y
		}
		if ink_bottom > bottom {
			bottom = ink_bottom
		}
		if start_x < left {
			left = start_x
		}
		if ink_right > right {
			right = ink_right
		}
		if gw <= 0 || gh <= 0 {
			continue
		}
		n := gw * gh
		if n > len(scratch) {
			continue
		}
		mem.zero(raw_data(scratch[:n]), n)
		stb.MakeCodepointBitmap(
			font,
			raw_data(scratch[:]),
			c.int(gw),
			c.int(gh),
			c.int(gw),
			layout.scale,
			layout.scale,
			glyph.codepoint,
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
				buf[o + 0] = ink.color[0]
				buf[o + 1] = ink.color[1]
				buf[o + 2] = ink.color[2]
				buf[o + 3] = u8(a)
			}
		}
	}
	if left > right || top > bottom {
		// Nothing revealed: the caller gets an empty rect rather than the layout's,
		// and treats it as "this clip has no ink this frame".
		return 0, 0, 0, 0
	}
	return left, top, right - left, bottom - top
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
	// One measurement buffer for every line, grown to the longest and reused:
	// subtitles are baked once per clip, not per frame, and this path already
	// allocates a line buffer per line from the same arena, so one more growing
	// buffer over the whole loop is the same trade with none of the per-line cost.
	line_layout: [dynamic]Text_Glyph

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
			&line_layout,
			{},
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
