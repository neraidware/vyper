// ---------------------------------------------------------------------------
// Glyph-atlas CPU probe (NERED_FONT_PROBE=1).
//
// Exercises the Unicode glyph cache's CPU core -- slot allocation, rune
// dedup, missing-rune marking, cell ordinal accounting, and grid growth --
// without a GPU or display (runs after load_font_data). The deferred
// rasterize/upload of cell pixels is a device-driven concern (the UI probe
// covers it once the render path moves over); this probe owns the layout
// invariants the upload pass depends on.
// ---------------------------------------------------------------------------
package main

import "core:c"
import "core:fmt"
import "core:os"

font_probe_failed: bool

font_probe_check :: proc(cond: bool, msg: string) {
	if !cond {
		fmt.println("[font-probe] FAIL:", msg)
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