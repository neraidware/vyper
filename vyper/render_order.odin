package vyper

import "core:fmt"

// The compositing draw order, stated ONCE for both pipelines.
//
// The preview and the export have to agree on paint order, and until now they
// each stated the rule in their own terms: the preview sorted slots by an
// integer key, while the export relied on the order `render_job.visuals` was
// built in plus a separate pass that painted subtitles last. Both were correct,
// and both were correct by coincidence -- nothing tied them together, so a new
// layer rule would have had to be written twice and would have been trusted
// twice. That is the failure mode that already produced three shipped
// preview/export parity bugs, so the rule lives here now and both sides call it.
//
// The export's paint loops and the preview's draw loop are deliberately NOT
// merged. The preview rasterises on the GPU from a fractional UV quad and the
// export blits CPU pixels out of the decode stage, so the backends have
// different output spaces and different per-item work; only the ORDER is
// shared. Forcing the loops together would mean one function with two
// unrelated halves and a branch per item, which is worse than a rule stated
// once and called twice.

// SUBTITLE_PIN_KEY is the draw depth reserved for pinned subtitle items. It sits
// below every track-assigned layer (the stack walk starts at 1), which is what
// makes "pinned on top" expressible: both pipelines draw the LOWEST key LAST.
SUBTITLE_PIN_KEY :: 0

// draw_key is the depth one compositable item sorts by. LOWER draws LATER and
// therefore ends up on top.
//
// Track order alone already gets ordinary clips right: `layer` is the stack
// walk position, the topmost track gets layer 1, and both pipelines walk their
// ordered list backwards, so the top track paints last. Burned-in subtitles
// are the exception -- they are pinned ABOVE every other clip, because a
// subtitle that a video covers is unreadable, and a subtitle clip on a low
// track must still land on top. That pinning is what `is_subtitle` selects.
//
// `layer` is passed separately rather than read off a clip or a slot because
// the two callers hold different things: the preview has a Preview_Slot whose
// `layer` field doubles as the flash-overlay depth (flash_rec.odin), where it
// must keep meaning "where this clip sits in the stack" and not "pinned above
// subtitles". Deriving the key at the draw site is what keeps those two
// meanings from collapsing into each other.
draw_key :: proc(layer: int, is_subtitle: bool) -> int {
	if is_subtitle {
		return SUBTITLE_PIN_KEY
	}
	return layer
}

// Both pipelines then sort ASCENDING by this key and walk the result backwards,
// so the topmost item is painted last. The sort direction is `<` on two
// draw_key results, which is why there is no separate comparator proc here:
// both callers already hold a key, and a comparator taking (layer, is_subtitle)
// pairs would only invite one of them to pass a precomputed key back in as if
// it were a layer.

// render_visual_layer_max bounds the export-side sort scratch. A render job's
// composite stack is one entry per clip on the timeline; 4096 clips is far past
// any real project and the sort refuses to run past it rather than silently
// truncating the order.
RENDER_VISUAL_LAYER_MAX :: 4096

// render_order_visuals orders the export's composite stack by draw_key, ascending
// — the same key and the same direction the preview sorts preview slots with, so
// the two pipelines cannot disagree about paint order by construction.
//
// `layers[i]` is the stack layer of `vis[i]`: the 1-based position of its track
// in the walk, matching the preview's `layer` (the topmost track is 1, both sides
// walk their ordered list backwards, so the top track paints last). It is
// recorded during the walk because position-in-the-list is not the same thing
// once the list has been sorted — and deriving the key from the list's own order
// would be circular.
//
// Why sort at all, when the walk already appends in stack order and the sort is
// therefore a no-op today? Because the dependency was invisible: the export's
// order came from the SHAPE of the walk rather than from draw_key, so editing
// draw_key moved the preview and left the export exactly as it was, with nothing
// failing. That is the same class of bug as the geometry snapshot — two places
// that had to agree, one of which was not actually consulting the rule. Stating
// the order here makes it a function of the rule, and a change to draw_key now
// reaches both sides.
//
// Subtitles are not in this list: they are pinned above everything and composited
// in their own trailing pass (render_worker_run). SUBTITLE_PIN_KEY is what makes
// that expressible, and it sits below every track layer.
render_order_visuals :: proc(vis: []Render_Visual, layers: []int) {
	assert(
		len(vis) == len(layers),
		"render_order_visuals: visual and layer arrays must be the same length",
	)
	assert(
		len(vis) <= RENDER_VISUAL_LAYER_MAX,
		"render_order_visuals: composite stack exceeds the sort bound",
	)
	// Insertion sort on draw_key. The list arrives in stack order already, so
	// this is linear in the common case, and it needs no comparator closure and
	// no key array — the key is draw_key(layers[i], false), computed inline.
	// Subtitles are absent (see above), so is_subtitle is false here.
	//
	// The entry being inserted is HELD across the shift loop, not re-read from
	// vis[i] at the end: the shift writes into vis[i] when the run reaches the
	// insertion slot, so re-reading it would place a shifted neighbour there
	// instead of the original. That silently corrupted tied layers.
	for i := 1; i < len(vis); i += 1 {
		item := vis[i]
		layer := layers[i]
		key := draw_key(layer, false)
		j := i - 1
		for j >= 0 && draw_key(layers[j], false) > key {
			vis[j + 1] = vis[j]
			layers[j + 1] = layers[j]
			j -= 1
		}
		vis[j + 1] = item
		layers[j + 1] = layer
	}
}

// render_order_visuals_probe builds a composite stack, shuffles the layer order,
// and asserts render_order_visuals puts it back in ascending draw_key order —
// so the export's ordering depends on the rule rather than on the shape of the
// walk that built the list.
//
// The shuffle is what makes this a real check. A test that only fed the list in
// stack order would pass whether or not the sort ran, because the walk already
// appends in that order; that is exactly the coincidence this change exists to
// remove, and it would let the sort rot back into a no-op unnoticed.
render_order_visuals_probe :: proc() -> bool {
	// Three sources on three layers, then a source on layer 2 as well so a tie
	// exists and the stable ordering can be observed.
	layers_src := [5]int{3, 1, 2, 2, 5}
	vis: [5]Render_Visual
	layers: [5]int
	// Dummy payloads: the sort only moves pointers and ints, and a nil-typed
	// union would trip the tag check, so point each at a distinct local.
	v0: Render_Video_Src
	v1: Render_Text_Src
	v2: Render_Text_Src
	v3: Render_Video_Src
	v4: Render_Text_Src
	payloads := [5]Render_Visual{&v0, &v1, &v2, &v3, &v4}
	for i in 0 ..< 5 {
		vis[i] = payloads[i]
		layers[i] = layers_src[i]
	}
	// Deliberately scrambled: 3,1,2,2,5 is already sorted, so permute to
	// 5,3,2,2,1 and confirm the sort restores ascending order.
	scrambled := [5]int{5, 3, 2, 2, 1}
	for i in 0 ..< 5 {
		layers[i] = scrambled[i]
	}
	render_order_visuals(vis[:], layers[:])
	ok := true
	for i := 1; i < 5; i += 1 {
		if draw_key(layers[i], false) < draw_key(layers[i - 1], false) {
			ok = false
		}
	}
	if !ok {
		fmt.println("[render-order-probe] FAIL: stack not in ascending draw_key order")
		return false
	}
	// The two layer-2 entries must keep their original relative order (stable),
	// which is what makes the result independent of the walk's clip order within
	// a track. After sorting they land at indices 1 and 2: layer 1 sorts ahead of
	// both, layer 3 and layer 5 behind.
	if vis[1] != payloads[2] || vis[2] != payloads[3] {
		fmt.println("[render-order-probe] FAIL: tied layers did not keep their relative order")
		return false
	}
	// A layer change must actually MOVE the entry: pin that the sort is not
	// simply returning its input. Without this, an identity implementation (a
	// sort that did nothing) would satisfy the ascending check on the scrambled
	// input only by luck.
	if vis[0] == payloads[0] && vis[4] == payloads[4] {
		fmt.println("[render-order-probe] FAIL: sort left the order untouched")
		return false
	}
	fmt.println("[render-order-probe] ok")
	return true
}
