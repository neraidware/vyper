// ---------------------------------------------------------------------------
// Glyph-atlas CPU probe (VYPER_FONT_PROBE=1).
//
// Exercises the Unicode glyph cache's CPU core -- slot allocation, rune
// dedup, missing-rune marking, cell ordinal accounting, and grid growth --
// without a GPU or display (runs after load_font_data). The deferred
// rasterize/upload of cell pixels is a device-driven concern (the UI probe
// covers it once the render path moves over); this probe owns the layout
// invariants the upload pass depends on.
// ---------------------------------------------------------------------------
package vyper

import "core:c"
import "core:fmt"
import "core:os"
import stb "vendor:stb/truetype"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {
	// The reveal cases below lay text out and paint it, which needs a font and a
	// scratch. They keep their OWN rather than using the app's shared text state,
	// for the same reason the render worker keeps its own: the globals belong to
	// the live frame loop and a probe must not touch them.
	font_probe_font: stb.fontinfo
	font_probe_font_init: bool
	font_probe_scratch: []u8
	font_probe_glyphs: [dynamic]Text_Glyph
	font_probe_inks: [dynamic]Text_Ink
	font_probe_order: [dynamic]int

	// font_probe_ink_of paints `title` into a throwaway buffer at the probe's own
	// font state and returns the inked rect. A proc rather than a closure because
	// Odin closures cannot capture a block-scoped [dynamic] that the callee mutates,
	// and because the reveal cases want to call it four times with different
	// windows.
	// font_probe_ink_of is the production path end to end: pieces go in, the
	// compositor resolves them into per-character ink, and the rasterizer paints
	// what it is told. Nothing here reaches past the graph to read a piece field,
	// because production does not either.
	// text_probe_build_chain is the two-piece topology, built directly so the
	// refusals above can rewire edges production never touches.
	text_probe_build_chain :: proc(graph: ^Node_Graph) {
		graph.nodes = make([dynamic]Compositor_Node, 0, 4)
		append(&graph.nodes, Compositor_Node{kind = .Text_Input})
		append(&graph.nodes, Compositor_Node{kind = .Style_Process, input_len = 3})
		append(&graph.nodes, Compositor_Node{kind = .Style_Process, input_len = 2})
		append(&graph.nodes, Compositor_Node{kind = .Text_Renderer})
		graph.sink = 3
		graph_connect(graph, 0, 1)
		graph_connect(graph, 0, 2)
		graph_connect(graph, 1, 3)
		graph_connect(graph, 2, 3)
		graph_connect(graph, 0, 3)
	}

	// tint_probe_ink_edges returns the RGB of the leftmost and rightmost inked
	// pixels of a paint, so a two-colour paint can be checked for putting each
	// colour on the right SIDE of the text rather than merely somewhere.
	tint_probe_ink_edges :: proc(
		title: string,
		bw, bh: int,
		pieces: Text_Pieces_Range,
		ink_x, ink_w, ink_h: int,
	) -> (first, last: [3]u8, found: bool) {
		buf := make([]u8, bw*bh*4)
		defer delete(buf)
		text_pieces_ink(pieces, len(title), &font_probe_inks, &font_probe_order)
		ox, oy, ow, oh := rasterize_title_into_buffer(
			title,
			buf,
			bw,
			bh,
			&font_probe_font,
			&font_probe_font_init,
			font_probe_scratch,
			&font_probe_glyphs,
			font_probe_inks[:],
			48,
		)
		for y in oy ..< oy + oh {
			for x in ox ..< ox + ow {
				o := (y * bw + x) * 4
				if buf[o + 3] == 0 {
					continue
				}
				pixel := [3]u8{buf[o + 0], buf[o + 1], buf[o + 2]}
				if !found {
					first = pixel
					found = true
				}
				last = pixel
			}
		}
		return first, last, found
	}

	font_probe_ink_of :: proc(
		title: string,
		bw, bh: int,
pieces: Text_Pieces_Range,
	inks: ^[dynamic]Text_Ink,
	order: ^[dynamic]int,
) -> (ox, oy, ow, oh: int) {
		buf := make([]u8, bw*bh*4)
		defer delete(buf)
		// The same entry production uses, implicit piece and all -- a probe that
		// built its own graph would be testing a path nothing runs.
		text_pieces_ink(pieces, len(title), inks, order)
		return rasterize_title_into_buffer(
			title,
			buf,
			bw,
			bh,
			&font_probe_font,
			&font_probe_font_init,
			font_probe_scratch,
			&font_probe_glyphs,
			inks[:],
			48,
		)
	}


	font_probe_failed: bool

	font_probe_check :: proc(cond: bool, msg: string, args: ..any) {
		if !cond {
			fmt.print("[font-probe] FAIL: ")
			fmt.eprintfln(msg, ..args)
			font_probe_failed = true
		}
	}

	font_probe_run :: proc() {
		atlas := Glyph_Atlas{}
		if !glyph_atlas_init(&atlas) {
			fmt.println("[font-probe] FAIL: glyph_atlas_init (need a session allocator)")
			os.exit(1)
		}

		// Fresh-state invariants.
		font_probe_check(atlas.cells_x == GLYPH_CELLS0, "initial grid side is GLYPH_CELLS0")
		font_probe_check(glyph_atlas_capacity(&atlas) == GLYPH_CELLS0 * GLYPH_CELLS0, "initial capacity is 16^2")
		font_probe_check(atlas.next_cell == 0 && atlas.slot_count == 0 && !atlas.needs_grow, "fresh atlas is empty")
		font_probe_check(atlas.generation == 0, "fresh atlas at generation 0")
		font_probe_check(MAX_GLYPH_SLOTS == GLYPH_CELLS_MAX * GLYPH_CELLS_MAX, "slot table equals the max grid cells")

		// First glyph: metrics + claims cell 0.
		s, ok, is_new := glyph_ensure(&atlas, 'A')
		font_probe_check(ok && is_new && s == 0, "A: first ensure is a new slot 0")
		g0 := &atlas.slots[s]
		font_probe_check(g0.rune == 'A' && g0.cell == 0, "A: rune recorded, cell 0")
		font_probe_check(g0.adv > 0 && g0.adv < 40, "A: sane advance")
		font_probe_check(g0.w > 0 && g0.h > 0, "A: has ink")
		font_probe_check(g0.w <= GLYPH_CELL_PX && g0.h <= GLYPH_CELL_PX, "A: ink fits a cell")
		font_probe_check(g0.yoff <= f32(g0.h), "A: ink top at or above ink bottom (positive-down)")

		// Dedup.
		s2, ok2, is_new2 := glyph_ensure(&atlas, 'A')
		font_probe_check(ok2 && !is_new2 && s2 == s, "A: second ensure dedups to the same slot")
		font_probe_check(atlas.slot_count == 1, "A: no second slot")

		// Space: metric-only glyph, no ink, no cell.
		ss, oks, _ := glyph_ensure(&atlas, ' ')
		font_probe_check(oks && atlas.slots[ss].adv > 0, "space: has an advance")
		font_probe_check(atlas.slots[ss].w == 0 && atlas.slots[ss].h == 0, "space: no ink")
		font_probe_check(atlas.slots[ss].cell == GLYPH_CELL_NONE, "space: claims no cell")
		font_probe_check(atlas.next_cell == 1, "space: consumed no cell")

		// Non-ASCII: U+00E9 (e-acute) must cache.
		se, oke, _ := glyph_ensure(&atlas, rune(0x00E9))
		font_probe_check(oke && atlas.slots[se].adv > 0, "e-acute: cached")
		font_probe_check(atlas.slots[se].w > 0 && atlas.slots[se].h > 0, "e-acute: has ink")
		font_probe_check(atlas.slots[se].cell == 1, "e-acute: claims cell 1")

		// Cell-ordinal -> grid (x, y): row-major.
		x, y := glyph_atlas_cell_xy(&atlas, 0)
		font_probe_check(x == 0 && y == 0, "cell 0 at the grid origin")
		x, y = glyph_atlas_cell_xy(&atlas, 17)
		font_probe_check(x == 1 && y == 1, "cell 17 is (1,1) on a 16-wide grid")

		// A rune the face lacks resolves once as missing and never re-probes.
		sm, okm, _ := glyph_ensure(&atlas, rune(0x1F600)) // emoji U+1F600: DejaVu Sans lacks it
		font_probe_check(!okm && sm == 0, "emoji: absent from the face -> no slot")
		font_probe_check(atlas.rune_map[0x1F600] == GLYPH_MAP_MISSING, "emoji: missing is marked")
		sm2, okm2, _ := glyph_ensure(&atlas, rune(0x1F600))
		font_probe_check(!okm2 && sm2 == 0, "emoji: repeat stays missing")
		font_probe_check(atlas.slot_count == 3, "emoji: consumed no slot")

		// Out-of-range runes are rejected, not cached.
		so, oko, _ := glyph_ensure(&atlas, rune(-1))
		font_probe_check(!oko && so == 0, "negative rune rejected")
		so2, oko2, _ := glyph_ensure(&atlas, rune(0x110000))
		font_probe_check(!oko2 && so2 == 0, "rune past 0x10FFFF rejected")

		// Capacity crossing sets needs_grow; grow_to_fit doubles the grid and
		// keeps cell ordinals valid under the new (row-major) mapping.
		atlas.next_cell = glyph_atlas_capacity(&atlas) // backdoor: grid starts full
		b0, okb, _ := glyph_ensure(&atlas, 'B')
		font_probe_check(okb && atlas.needs_grow, "B past capacity requests a grow")
		font_probe_check(atlas.generation == 0, "grow not applied yet (deferred)")
		glyph_atlas_grow_to_fit(&atlas)
		font_probe_check(atlas.cells_x == 32, "grow doubles the grid side to 32")
		font_probe_check(atlas.generation == 1, "grow bumps the generation")
		font_probe_check(!atlas.needs_grow, "grow clears the flag")
		bx, by := glyph_atlas_cell_xy(&atlas, atlas.slots[b0].cell)
		font_probe_check(bx == 0 && by == 8, "cell 256 maps to (0,8) on a 32-wide grid")
		x, y = glyph_atlas_cell_xy(&atlas, 0)
		font_probe_check(x == 0 && y == 0, "cell 0 still at the origin after grow")

		// grow_to_fit is a no-op while the grid still fits.
		n := atlas.generation
		glyph_atlas_grow_to_fit(&atlas)
		font_probe_check(atlas.generation == n, "no-op grow keeps the generation")

		// Second capacity crossing grows to the max grid.
		atlas.next_cell = 1024 // backdoor: fill the 32^2 grid
		c0, okc, _ := glyph_ensure(&atlas, 'C')
		font_probe_check(okc && atlas.needs_grow, "C past 32^2 requests a grow")
		glyph_atlas_grow_to_fit(&atlas)
		font_probe_check(atlas.cells_x == GLYPH_CELLS_MAX, "final grow reaches the max grid side")
		font_probe_check(atlas.generation == 2, "second grow bumps the generation")
		cx, cy := glyph_atlas_cell_xy(&atlas, atlas.slots[c0].cell)
		font_probe_check(cx == 0 && cy == 16, "cell 1024 maps to (0,16) on a 64-wide grid")

		// --- per-character reveal ---------------------------------------------
		// The typing window. What matters is not that fewer pixels appear but WHERE
		// the text's geometry comes from: the whole string is still laid out, and
		// only the glyphs outside the window are skipped at paint time. So typing
		// does not reflow -- a character revealed later lands in the position it
		// would have had all along, with its neighbours' kerning applied.
		//
		// A per-character feature built on the opposite shape -- painting a revealed
		// PREFIX as its own string -- would re-measure and shift on every reveal,
		// and this is the assertion that keeps that from creeping back in.
		{
			title := "AV Wa"
			bw, bh := text_buf_size_for(title, &font_probe_font, &font_probe_font_init, 48)
			font_probe_check(bw > 0 && bh > 0, "reveal: the buffer must size")
			font_probe_scratch = make([]u8, text_scratch_size_for(48))
			defer delete(font_probe_scratch)
			// Sized up front: the evaluator writes into a caller-owned table rather
			// than growing one, because it runs once per bake and must not allocate.
			resize(&font_probe_inks, 256)
			resize(&font_probe_order, 64)
			defer delete(font_probe_inks)
			defer delete(font_probe_order)

			layout := text_layout_into(title, &font_probe_font, &font_probe_font_init, 48, &font_probe_glyphs)
			font_probe_check(
				len(layout.glyphs) == 5,
				"reveal: a 5-character text must lay out 5 glyphs (got %d)",
				len(layout.glyphs),
			)
			// Monotonic char_index is what makes the range test meaningful: the
			// painter's only decision is `first <= char_index < last`.
			monotonic := true
			for glyph, index in layout.glyphs {
				if glyph.char_index != index {
					monotonic = false
					break
				}
			}
			font_probe_check(monotonic, "reveal: char_index must run 0..n-1 in layout order")

			// No pieces at all draws everything: the implicit single piece.
			_, _, all_w, all_h := font_probe_ink_of(title, bw, bh, {}, &font_probe_inks, &font_probe_order)
			// One piece over the whole text, revealing only its first character.
			first_only := Text_Pieces_Range{}
			session_piece_push(
				&first_only,
				Text_Piece{start = 0, len = 5, reveal = Text_Reveal{first = 0, last = 1}},
			)
			_, _, one_w, one_h := font_probe_ink_of(title, bw, bh, first_only, &font_probe_inks, &font_probe_order)
			// Narrower, and no taller. Not "the same height": a round letter overshoots
			// the baseline by a pixel, so "AV Wa" is legitimately 1px taller than the
			// "A" alone -- the first assertion I wrote here failed on exactly that, and
			// the height was right all along.
			font_probe_check(
				all_w > one_w && all_h >= one_h && one_h > 0,
				"reveal: one character must be narrower than five and no taller (%dx%d vs %dx%d)",
				one_w,
				one_h,
				all_w,
				all_h,
			)
			none_shown := Text_Pieces_Range{}
			session_piece_push(&none_shown, Text_Piece{start = 0, len = 0})
			_, _, zero_w, zero_h := font_probe_ink_of(title, bw, bh, none_shown, &font_probe_inks, &font_probe_order)
			font_probe_check(
				zero_w == 0 && zero_h == 0,
				"reveal: an empty window must paint no ink (got %dx%d)",
				zero_w,
				zero_h,
			)
			// A window open from either end, not just the front.
			from_back := Text_Pieces_Range{}
			session_piece_push(
				&from_back,
				Text_Piece{start = 0, len = 5, reveal = Text_Reveal{first = 1, last = 5}},
			)
			short_head := Text_Pieces_Range{}
			session_piece_push(
				&short_head,
				Text_Piece{start = 0, len = 5, reveal = Text_Reveal{first = 0, last = 4}},
			)
			_, _, tail_w, _ := font_probe_ink_of(title, bw, bh, from_back, &font_probe_inks, &font_probe_order)
			_, _, head_w, _ := font_probe_ink_of(title, bw, bh, short_head, &font_probe_inks, &font_probe_order)
			font_probe_check(
				tail_w < all_w && head_w < all_w,
				"reveal: a window open from either end must be narrower than the whole (%d/%d/%d)",
				head_w,
				tail_w,
				all_w,
			)
			// Revealing nothing must not change the MEASUREMENT. The reflow property,
			// stated as an assertion rather than left as a comment.
			after := text_layout_into(title, &font_probe_font, &font_probe_font_init, 48, &font_probe_glyphs)
			font_probe_check(
				len(after.glyphs) == 5 && after.width == layout.width,
				"reveal: laying out again after an empty paint must still measure the whole text (%d glyphs)",
				len(after.glyphs),
			)
			session_piece_release(first_only)
			session_piece_release(none_shown)
			session_piece_release(from_back)
			session_piece_release(short_head)

			// --- the graph refuses what a graph cannot be ----------------------
			// A cycle check on a hardcoded topology guards nothing, because a
			// hardcoded topology cannot cycle. These are the refusals that make
			// "it is a graph" true rather than asserted.
			{
				graph := Node_Graph{}
				text_probe_build_chain(&graph)
				// renderer <- style <- input already. Wiring input back from the
				// renderer closes a loop, so it must be refused.
				font_probe_check(
					!graph_connect(&graph, graph.sink, 0),
					"graph: a connection that would close a cycle must be refused",
				)
				// A renderer emits an IMAGE, so nothing may feed it from a node
				// that emits text where an image is expected -- and no node kind
				// takes an image yet, which is what makes "input -> track" impossible
				// rather than merely discouraged.
				font_probe_check(
					!node_pin_accepts(.Style_Process, .Image),
					"graph: a process must not accept an image; only the renderer promotes",
				)
				font_probe_check(
					node_pin_emits(.Text_Renderer) == .Image &&
						node_pin_emits(.Text_Input) == .Text,
					"graph: only the renderer may emit an image",
				)
				// A branch that fans out and reconverges. Nothing in a node's shape
				// says how many things feed it, so a source driving three processes
				// that all reach one renderer is the SAME construction as a chain --
				// the difference is two more edges. A per-node input array would have
				// needed a struct change and a slot-index convention to get here.
				{
					branch := Node_Graph{}
					branch.nodes = make([dynamic]Compositor_Node, 0, 5)
					append(&branch.nodes, Compositor_Node{kind = .Text_Input})
					append(&branch.nodes, Compositor_Node{kind = .Style_Process, input_len = 1})
					append(&branch.nodes, Compositor_Node{kind = .Style_Process, input_len = 2})
					append(&branch.nodes, Compositor_Node{kind = .Style_Process, input_start = 2, input_len = 3})
					append(&branch.nodes, Compositor_Node{kind = .Text_Renderer})
					branch.sink = 4
					font_probe_check(graph_connect(&branch, 0, 1), "branch: source feeds first process")
					font_probe_check(graph_connect(&branch, 0, 2), "branch: source feeds second process")
					font_probe_check(graph_connect(&branch, 0, 3), "branch: source feeds third process")
					font_probe_check(graph_connect(&branch, 1, 4), "branch: first process reconverges")
					font_probe_check(graph_connect(&branch, 2, 4), "branch: second process reconverges")
					font_probe_check(graph_connect(&branch, 3, 4), "branch: third process reconverges")
					font_probe_check(len(branch.edges) == 6, "branch: six edges, not a slot count")
					// ...and it evaluates: the last style to annotate a character wins,
					// which is the only ordering rule a reconvergence needs.
					branch_inks := make([dynamic]Text_Ink, 5)
					defer delete(branch_inks)
					branch_order := make([dynamic]int, 0, 16)
					defer delete(branch_order)
					graph_eval_text(&branch, 5, branch_inks[:], &branch_order)
					// The declared ranges are [0,1), [0,2), [2,5) -- so chars 0..4
					// are all claimed by at least one process, and the reconvergence is
					// what lets the LAST process win for char 0.
					font_probe_check(
						branch_inks[0].drawn && branch_inks[1].drawn && branch_inks[2].drawn,
						"branch: a branching graph must still resolve ink",
					)
					text_graph_free(&branch)
				}

				// And the built topology really is the design's: input, one style per
				// piece, renderer.
				font_probe_check(
					len(graph.nodes) == 4 && graph.nodes[0].kind == .Text_Input &&
						graph.nodes[1].kind == .Style_Process &&
						graph.nodes[2].kind == .Style_Process &&
						graph.nodes[3].kind == .Text_Renderer,
					"graph: a two-piece clip must build input, two styles and a renderer",
				)
				text_graph_free(&graph)
			}

			// --- two pieces, each revealing itself -----------------------------
			// This is the case a clip-level reveal cannot express: one window over
			// the whole text, and another over one word inside it. Both are the same
			// kind of thing, which is the point -- a property lives on a piece.
			split := Text_Pieces_Range{}
			session_piece_push(
				&split,
				Text_Piece{start = 0, len = 3, reveal = Text_Reveal{first = 0, last = 3}},
			)
			session_piece_push(
				&split,
				Text_Piece{start = 3, len = 2, reveal = Text_Reveal{first = 0, last = 1}},
			)
			_, _, split_w, _ := font_probe_ink_of(title, bw, bh, split, &font_probe_inks, &font_probe_order)
			font_probe_check(
				split_w > one_w && split_w < all_w,
				"pieces: two independently revealed runs must land between one character and the whole (%d)",
				split_w,
			)
			// The second piece's reveal is PIECE-LOCAL: it says "1 of this piece",
			// and piece two starts at character 3. A clip-level range would have had
			// to be rewritten to 3..4 here, which is the translation the piece's
			// coordinates remove.
			split_inks := make([dynamic]Text_Ink, 5)
			defer delete(split_inks)
			{
				graph := Node_Graph{}
				font_probe_check(
					text_graph_build(&graph, 5, split),
					"graph: a two-piece text must build",
				)
				graph_eval_text(&graph, 5, split_inks[:], &font_probe_order)
				text_graph_free(&graph)
			}
			font_probe_check(
				split_inks[3].drawn && !split_inks[4].drawn,
				"pieces: a piece-local reveal must index from the piece's own start (%v/%v)",
				split_inks[3],
				split_inks[4],
			)
			// A character no piece claims draws nothing.
			gap := Text_Pieces_Range{}
			session_piece_push(
				&gap,
				Text_Piece{start = 0, len = 2, reveal = Text_Reveal{first = 0, last = 2}},
			)
			gap_inks := make([dynamic]Text_Ink, 5)
			defer delete(gap_inks)
			{
				graph := Node_Graph{}
				font_probe_check(text_graph_build(&graph, 5, gap), "graph: a gap text must build")
				graph_eval_text(&graph, 5, gap_inks[:], &font_probe_order)
				text_graph_free(&graph)
			}
			font_probe_check(
				!gap_inks[4].drawn,
				"pieces: a character past the last piece must not be drawn",
			)
			session_piece_release(split)
			session_piece_release(gap)

			// --- colour, through the compositor --------------------------------
			// The first property to live on a piece, and the reason the piece list is
			// a graph: a per-character colour is not a special case of the text model,
			// it is a ONE-CHARACTER style node. Two runs in two inks is the same
			// structure with a different length, and the rasterizer learned nothing
			// new to paint them -- it was handed two different answers.
			red := [3]u8{255, 0, 0}
			blue := [3]u8{0, 0, 255}
			tinted := Text_Pieces_Range{}
			session_piece_push(&tinted, Text_Piece{start = 0, len = 3, color = red})
			session_piece_push(&tinted, Text_Piece{start = 3, len = 2, color = blue})
			inks := make([dynamic]Text_Ink, 5)
			defer delete(inks)
			order2 := make([dynamic]int, 0, 16)
			defer delete(order2)
			text_pieces_ink(tinted, 5, &inks, &order2)
			font_probe_check(
				inks[0].drawn && inks[2].drawn && inks[0].color == red && inks[3].color == blue,
				"colour: two style nodes must resolve their own ranges (%v/%v)",
				inks[0],
				inks[3],
			)
			// Asserted on WHERE the ink lands, not merely that both colours appear:
			// a raster holding both colours somewhere would also pass if the node
			// order or the character mapping were wrong.
			tint_x, _, tint_w, tint_h := font_probe_ink_of(
				title, bw, bh, tinted, &font_probe_inks, &font_probe_order,
			)
			font_probe_check(tint_w > 0 && tint_h > 0, "colour: two inked pieces must produce ink")
			first_ink, last_ink, found_any := tint_probe_ink_edges(title, bw, bh, tinted, tint_x, tint_w, tint_h)
			font_probe_check(
				found_any && first_ink == red,
				"colour: the leftmost inked pixel must be the FIRST piece's (%v, want %v)",
				first_ink, red,
			)
			font_probe_check(
				last_ink == blue,
				"colour: the rightmost inked pixel must be the LAST piece's (%v, want %v)",
				last_ink, blue,
			)
			// A piece with no colour is white, so nothing that existed before pieces
			// changes appearance.
			unstyled := Text_Pieces_Range{}
			session_piece_push(&unstyled, Text_Piece{start = 0, len = 5, color = TEXT_INK_DEFAULT_RGB})
			_, _, styled_w, styled_h := font_probe_ink_of(
				title, bw, bh, unstyled, &font_probe_inks, &font_probe_order,
			)
			blank_first, _, found_blank := tint_probe_ink_edges(title, bw, bh, unstyled, tint_x, tint_w, tint_h)
			font_probe_check(
				found_blank && blank_first == TEXT_INK_DEFAULT_RGB,
				"colour: a piece with no colour must paint default ink (%v)",
				blank_first,
			)
			font_probe_check(
				styled_w == all_w && styled_h == all_h,
				"colour: an unstyled piece must have the same extents as the fast path",
			)
			session_piece_release(tinted)
			session_piece_release(unstyled)
		}

		if font_probe_failed {
			os.exit(1)
		}
		fmt.printf(
			"[font-probe] OK: grid %dx%d gen %d slots %d cells %d (non-ASCII cached on demand)\n",
			atlas.cells_x,
			atlas.cells_x,
			atlas.generation,
			atlas.slot_count,
			atlas.next_cell,
		)
		glyph_atlas_destroy(&atlas)
		os.exit(0)
	}
}
