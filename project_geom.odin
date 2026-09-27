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
