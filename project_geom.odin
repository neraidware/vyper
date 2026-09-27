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
