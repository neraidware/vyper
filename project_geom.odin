package main

import "core:c"

// Project-space clip geometry, shared by the editor preview and the export
// compositor.
//
// This file exists because both subsystems need the same two answers -- "how
// big is this clip's uncropped box" and "where is its cropped box" -- and were
// keeping separate copies. The copies had already drifted into claiming
// agreement they did not have (see TODO.md Active 10), and a preview that
// disagrees with the export about where a clip lands is a WYSIWYG bug, not a
// style issue.
//
// Everything here is PURE and takes the canvas size as a parameter. That is not
// tidiness: the export compositor runs on a worker thread against a Render_Job
// snapshot precisely so it never reads live timeline state, so it cannot use a
// helper that reaches for the `project` globals. The preview, which legitimately
// reads live state, wraps the first one to supply them.

// full_box_dims returns the UNCROPPED full-image size in project units for a
// clip at `scale`, measured from the SOURCE's own pixels: scale 1 is the clip
// at native size (1 source pixel = 1 project-canvas pixel), uniform in both
// axes so the clip never distorts. A zero source dimension means the size is
// not known yet, and the canvas box is the fallback (stretch-to-fill).
full_box_dims :: proc(sw0, sh0: c.int, scale, pw, ph: f32) -> (f32, f32) {
	if sw0 > 0 && sh0 > 0 {
		return f32(sw0) * scale, f32(sh0) * scale
	}
	return pw * scale, ph * scale
}

// cropped_box_edges returns the visible (cropped) box EDGES of a clip centered
// at (cx, cy) whose uncropped full box is (fw, fh), given normalized crop
// insets. Edges rather than an origin+extent because the export rounds the edges
// to whole output pixels and the preview hands floats to the GPU quad; deriving
// an extent from these edges is what keeps the two from disagreeing on width by
// the last ULP.
//
// Precedence is crop, then scale: the inset takes a fraction of the FULL box, so
// dragging an edge inward shrinks the visible window without moving the opposite
// edge by more than the crop itself.
cropped_box_edges :: proc(
	cx, cy, fw, fh: f32,
	crop_l, crop_r, crop_t, crop_b: f32,
) -> (l, t, r, b: f32) {
	l = cx - fw / 2 + crop_l * fw
	r = cx + fw / 2 - crop_r * fw
	t = cy - fh / 2 + crop_t * fh
	b = cy + fh / 2 - crop_b * fh
	return
}

// px_extent converts a float SPAN (a width or height) to a pixel count, rounding
// half up and never returning less than 1.
//
// The floor is the point, not the rounding: every caller is sizing a blit rect
// or a GPU texture, and a zero-sized one is not a small image, it is an invalid
// one -- SDL rejects the texture and a zero-area quad divides by zero in the
// shader. The floor is also the answer to "what does a crop that rounds to
// nothing mean": one pixel, which is the same thing every one of those callers
// already did by hand.
//
// Origins are NOT this and must not be routed through it. An origin is
// `c.int(math.round(v))` with no floor, because a clip can legitimately hang off
// the canvas at a negative coordinate. Rounding an origin half UP and clamping
// it to 1 would teleport every off-canvas clip to the top-left corner.
px_extent :: proc(span: f32) -> c.int {
	return max(1, c.int(span + 0.5))
}

// Crop_Src_Rect is a source pixel region selected by a clip's crop insets.
Crop_Src_Rect :: struct {
	x, y: int,
	w, h: int,
}

// crop_src_rect resolves normalized crop insets over an image of (fw, fh) into
// the SOURCE PIXEL RECT they select: origin from the leading insets, extent from
// the remaining span, both rounded to nearest and clamped to stay inside the
// image.
//
// The name says SOURCE, not destination, because the insets are a fraction of
// the source: where those pixels land on screen is cropped_box_edges' job. The
// destination rect is intentionally derived separately, so a caller cannot
// accidentally reuse this one for both.
//
// Shared because the export has TWO paths that must agree on this answer, and
// were computing it separately. The GPU path takes the rect in the STAGED
// texture (which holds the full uncropped frame), the CPU sws path takes it in
// the full-box blit (same pixels, different buffer). keyed_export measures GPU
// output against the CPU path as its reference, so the two agreeing is the
// premise of that PSNR gate -- a rounding or clamp policy that drifted between
// them would quietly lower the score instead of failing, which is the one
// failure mode a reference-comparison gate cannot catch.
//
// Arithmetic is f32 to match the GPU path, which is the one with a bit-exact
// gate (keyed_export inf at 1:1) and therefore the strictest opinion on what the
// correct rounding is. The CPU path adopted f32 to match it; the gate's PSNR is
// unmoved, so the difference was never load-bearing.
crop_src_rect :: proc(fw, fh: int, crop_l, crop_r, crop_t, crop_b: f32) -> Crop_Src_Rect {
	fw32 := f32(fw)
	fh32 := f32(fh)
	r := Crop_Src_Rect {
		x = clamp(int(f32(crop_l) * fw32 + 0.5), 0, fw - 1),
		y = clamp(int(f32(crop_t) * fh32 + 0.5), 0, fh - 1),
	}
	// Extent is bounded by what is LEFT after the origin, not by the full image,
	// so a crop right at the far edge cannot ask for a rect that runs off it.
	r.w = clamp(int(fw32 * (1.0 - crop_l - crop_r) + 0.5), 1, fw - r.x)
	r.h = clamp(int(fh32 * (1.0 - crop_t - crop_b) + 0.5), 1, fh - r.y)
	return r
}

// text_pixels_to_project is the uniform factor mapping TEXT pixels to project
// units, given the canvas width `pw`.
//
// One factor for both axes on purpose: text is rasterized into a buffer sized to
// the ink, and letting x and y scale independently would stretch the glyphs
// whenever the project's aspect differs from 16:9. Both sinks derive their text
// box through here so a text clip's box is the same shape in the preview and in
// the export; they used to spell `f32(w) / f32(PREVIEW_W)` out at six sites,
// and the preview's own copy disagreed with the export's about the HEIGHT in
// particular (preview used the font's metric line box, export the tight ink
// rect, which are different quantities).
//
// `pw` is the canvas width in whichever space the caller is working in — the
// preview's letterboxed view, or the export's output width — because the factor
// is "canvas pixels per PREVIEW_W project pixels" in both cases.
text_pixels_to_project :: proc(text_px: f32, pw: f32) -> f32 {
	return text_px * pw / f32(PREVIEW_W)
}

// text_box_dims is a text clip's box size in project units from its BASE ink
// dims at font 48 and the clip's SAMPLED scale.
//
// `base_w` is the tight ink width and `base_h` the font's metric line-box height
// (ascent + descent + TEXT_BOX_PAD), both at font 48 and scale-independent —
// which is what clip.source_w/source_h carry. `scale` is the sampled Scale lane,
// not the clip's resting field, so a keyed scale produces the box it previews.
//
// Both sinks call this rather than multiplying the dims themselves: the export
// used to scale its raster's MEASURED ink rect instead of these base dims, so
// the two boxes differed by however much air the metric box carries around the
// ink. Passing the base dims is what makes them one box.
text_box_dims :: proc(base_w, base_h: c.int, scale, pw: f32) -> (f32, f32) {
	f := text_pixels_to_project(1, pw)
	return f32(base_w) * f * scale, f32(base_h) * f * scale
}

// ---------------------------------------------------------------------------
// The content window: crop, then zoom, then pan.
//
// Crop says HOW MUCH of the source a clip shows; Zoom says how magnified that
// window is; Pan says WHERE it sits within the source. This proc resolves the
// three into the four normalized insets that every downstream consumer already
// speaks, so nothing downstream has to know the three exist.
//
// One resolver, both sinks. The preview needs the window for its crop UVs and
// the export needs it for crop_src_rect, and they used to be derived by
// different code from different inputs -- the preview from sampled lanes, the
// export from `geom_base` -- which is exactly the shape of bug that made keyed
// text export at its resting pose (TODO.md Active 24). Resolving here, from a
// Geom_Sample, means a caller cannot pick the wrong one.
// ---------------------------------------------------------------------------

// Zoom_Floor is the smallest window Zoom may shrink to, as a fraction of the
// source. Below this the window has no meaningful content left and, more
// practically, the integer source rect crop_src_rect derives stops resolving to
// anything drawable.
Zoom_Floor :: 0.05

// Source_Window is the resolved window as normalized insets, the same shape and
// units as clip.crop_l/r/t/b — so the result drops straight into every existing
// crop consumer without conversion.
Source_Window :: struct {
	l, r, t, b: f32,
}

// geom_source_window resolves `geom`'s crop, zoom and pan into one window.
//
// `zoom` is uniform (see Render_Geom_Prop.Zoom): both axes share it, because
// scaling them differently would change the box's aspect ratio. A zoom of 1
// leaves the crop window exactly as crop describes it, and a zoom of 0 — which
// is what a bare `Clip{}` carries — means 1, so the zero value is useful and a
// clip constructed by a probe or a loader is not silently invisible.
//
// `pan_x`/`pan_y` are fractions of the ZOOMED window's own width and height, so
// a pan of 0.5 always slides by half a window regardless of zoom, and the
// gesture that produces them does not have to rescale itself when zoom changes.
// Positive slides the WINDOW toward the source's LEFT/top, so the content
// appears to move right/down -- which is what makes a rightward drag move the
// image rightward. Pan is the window's offset, not the content's; conflating the
// two is what inverted the gesture once.
//
// Every stage clamps to the source. A window that ran off an edge would ask
// crop_src_rect for a rect it cannot address, and the export's stage-clamping
// would silently substitute the wrong pixels — the "box moves a pixel" class of
// bug, one stage further from its cause.
// Source_Window_Parts is the window's geometry BEFORE pan: where it sits and how
// big it is. Split out because the clamp rule needs it too, and a pan range
// re-derived from the insets instead would be a second answer to "how far can
// this axis slide".
Source_Window_Parts :: struct {
	cx, cy: f32, // the ZOOMED window's center (the crop window's, when centered)
	nw, nh: f32, // the zoomed window's size, as fractions of the source
}

source_window_parts :: proc(geom: Geom_Sample) -> Source_Window_Parts {
	wl := geom[int(Render_Geom_Prop.Crop_L)]
	wr := 1 - geom[int(Render_Geom_Prop.Crop_R)]
	wt := geom[int(Render_Geom_Prop.Crop_T)]
	wb := 1 - geom[int(Render_Geom_Prop.Crop_B)]
	// A degenerate crop (insets summing past the edge) would give a negative
	// width and every clamp below would invert. Fall back to the full frame, which
	// is what an unset crop means.
	wx := wr - wl
	wy := wb - wt
	if !(wx > 0.0) || !(wy > 0.0) {
		wl, wr, wt, wb = 0, 1, 0, 1
		wx, wy = 1, 1
	}
	zoom := geom[int(Render_Geom_Prop.Zoom)]
	if !(zoom > 0.0) {
		zoom = 1.0 // the zero value means "no magnification"
	}
	// About the crop window's center, so zoom leaves a centered crop centered.
	return {
		cx = (wl + wr) * 0.5,
		cy = (wt + wb) * 0.5,
		nw = min(max(wx / zoom, Zoom_Floor), 1.0),
		nh = min(max(wy / zoom, Zoom_Floor), 1.0),
	}
}

geom_source_window :: proc(geom: Geom_Sample) -> Source_Window {
	p := source_window_parts(geom)
	nl := p.cx - p.nw * 0.5 - geom[int(Render_Geom_Prop.Pan_X)] * p.nw
	nt := p.cy - p.nh * 0.5 - geom[int(Render_Geom_Prop.Pan_Y)] * p.nh
	// Clamp as a whole: shifting one edge and re-deriving the other keeps the
	// window's SIZE, so a pan past the border pins instead of shrinking — which
	// is what the Alt+middle gesture has always done.
	nl = clamp(nl, 0, 1 - p.nw)
	nt = clamp(nt, 0, 1 - p.nh)
	return {l = nl, r = 1 - (nl + p.nw), t = nt, b = 1 - (nt + p.nh)}
}

// Source_Pan_Range is the set of pan values an axis can actually take: the ones
// for which the window clamp above is not binding.
Source_Pan_Range :: struct {
	x_lo, x_hi: f32,
	y_lo, y_hi: f32,
}

// geom_pan_range returns the achievable pan values for both axes.
//
// This exists because clamping the WINDOW is not the same as bounding the VALUE,
// and only the second one keeps the property honest. With the clamp living solely
// in geom_source_window, dragging toward an edge kept incrementing pan_x forever
// while the content sat pinned — the number ran away from the picture, and the
// inspector and any keyframe taken from it recorded a pan the clip was never
// showing. A gesture can reach a pan the window refuses, so the bound has to be
// available to whoever writes the value, not just to whoever renders it.
//
// Derived from the same parts the window is, inverted:
//
//	pan in [ (cx - nw/2 - (1-nw)) / nw , (cx - nw/2) / nw ]
//
// which is just `nl` at each end of its clamp, divided by nw. Zoom_Floor keeps nw
// away from zero, so the division is always safe.
geom_pan_range :: proc(geom: Geom_Sample) -> Source_Pan_Range {
	p := source_window_parts(geom)
	return {
		x_lo = (p.cx - p.nw * 0.5 - (1 - p.nw)) / p.nw,
		x_hi = (p.cx - p.nw * 0.5) / p.nw,
		y_lo = (p.cy - p.nh * 0.5 - (1 - p.nh)) / p.nh,
		y_hi = (p.cy - p.nh * 0.5) / p.nh,
	}
}

// clamp_pan_x / clamp_pan_y bound a pan value to what the window can show, so a
// stored value and the visible window cannot disagree. The gesture routes its
// writes through these; so should anything else that writes a pan.
clamp_pan_x :: proc(geom: Geom_Sample, v: f32) -> f32 {
	r := geom_pan_range(geom)
	return clamp(v, r.x_lo, r.x_hi)
}

clamp_pan_y :: proc(geom: Geom_Sample, v: f32) -> f32 {
	r := geom_pan_range(geom)
	return clamp(v, r.y_lo, r.y_hi)
}

// geom_content_insets is the CONTENT window's four normalized insets — crop, then
// zoom, then pan. This is what selects WHICH SOURCE PIXELS are drawn: the export's
// crop_src_rect and the preview's crop UVs.
//
// It is NOT what sizes or places the clip's box. Those read clip.crop_l/r/t/b
// directly, and the distinction is load-bearing rather than cosmetic:
//
// cropped_box_edges treats insets as box TRIMS — `l` pulls the box's left edge
// inward — so an asymmetric inset pair moves the box. Zoom and pan produce
// asymmetric insets exactly when they should not move anything: a pan slides the
// window off-center on purpose, and a zoom about an ASYMMETRIC crop window's
// center inherits that window's offset. Feeding these insets to the box moves the
// clip by 0.1 of its width on a quarter pan, and by a fifth of it on an
// asymmetric crop at 2x — which is precisely the "zoom must not touch placement"
// rule. Zoom and pan select content; only crop trims the box.
geom_content_insets :: proc(geom: Geom_Sample) -> (l, r, t, b: f32) {
	w := geom_source_window(geom)
	return w.l, w.r, w.t, w.b
}

// geom_box_insets is the clip's BOX insets — the crop lanes and nothing else.
// The one accessor for the box side, so a caller cannot reach for the content
// window by mistake; that mistake is invisible until a clip drifts under the
// pointer.
geom_box_insets :: proc(geom: Geom_Sample) -> (l, r, t, b: f32) {
	return geom[int(Render_Geom_Prop.Crop_L)],
	       geom[int(Render_Geom_Prop.Crop_R)],
	       geom[int(Render_Geom_Prop.Crop_T)],
	       geom[int(Render_Geom_Prop.Crop_B)]
}

// cl_geom_all samples EVERY lane of a live clip at the playhead — the whole
// Geom_Sample, not one lane. geom_pan_range needs the crop and zoom lanes to
// bound a pan, so a caller holding only a Clip cannot clamp a pan against a
// partial sample: a range computed from a resting crop while the playhead is on a
// keyed one would admit pan values the window refuses.
//
// The one place the preview and export evaluators both take this shape.
cl_geom_all :: proc(clip: ^Clip) -> Geom_Sample {
	return geom_sample_clip(clip, playhead.frame)
}
