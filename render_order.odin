package main

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
