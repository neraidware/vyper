package main

// NERED_TRANSFORM_PROBE — regression check for the edge-handle "snap freeze".
// Reported bug: after a resize handle's driven edge snaps to a canvas border,
// moving the cursor further made the box keep rescaling on the opposite
// (pinned) edge — the box overflowed instead of stopping at the border. The fix
// (`handle_drag_frozen`) holds the box at its snapped geometry while the cursor
// stays beyond the border; resize resumes only once the pointer comes back past
// the snap threshold.
//
// Each case: build a full-canvas box, grab an edge handle exactly on its border,
// push the cursor beyond that border, assert NO resize (opposite edge stays
// pinned, driven edge stays on the border); then move the cursor back INSIDE
// the canvas and assert resize resumes (driven edge follows the pointer, opposite
// edge unchanged).

import "core:fmt"
import "core:os"
import clay "clay-odin"

mk_probe_clip :: proc() -> (c: Clip) {
	c.kind = .Video
	c.generator = .None
	c.source_w = 16
	c.source_h = 9
	c.transform_x = f32(project.width) / 2
	c.transform_y = f32(project.height) / 2
	c.scale = 1.0
	return
}

// probe_canvas maps pixel space 1:1 onto project resolution (identity camera,
// canvas == project size), so pixel<->project conversions are identity.
probe_canvas :: proc() -> clay.BoundingBox {
	preview_cam_zoom = 1
	preview_cam_ox = 0
	preview_cam_oy = 0
	return {x = 0, y = 0, width = f32(project.width), height = f32(project.height)}
}

probe_visible_edges :: proc(c: ^Clip) -> (l, r, t, b: f32) {
	PW := f32(project.width)
	PH := f32(project.height)
	cw2, ch2 := clip_full_box_dims(c, PW * c.scale, PH * c.scale)
	dl := (0.5 - c.crop_l) * cw2
	dr := (0.5 - c.crop_r) * cw2
	dt := (0.5 - c.crop_t) * ch2
	db := (0.5 - c.crop_b) * ch2
	return c.transform_x - dl, c.transform_x + dr, c.transform_y - dt, c.transform_y + db
}

transform_probe_run :: proc(v: string) {
	PW := f32(project.width)
	PH := f32(project.height)
	canvas := probe_canvas()

	fail := false
	check :: proc(fail: ^bool, cond: bool, msg: string, l, r, t, b: f32) {
		if !cond {
			fail^ = true
			fmt.printf("[transform-probe] FAIL %s (box l=%.1f r=%.1f t=%.1f b=%.1f)\n", msg, l, r, t, b)
		}
	}

	// --- Case 1: TOP handle (1), top edge snapped at y=0. Cursor pushed ABOVE
	// the canvas top. Frozen: box must NOT change (no overflow, no opposite-edge
	// growth).
	{
		c := mk_probe_clip() // full-canvas box: t=0, b=PH
		_, _, t0, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 1, PW / 2, t0, false)
		update_handle_drag(&c, canvas, PW / 2, -2000, false) // beyond top border
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, t >= -0.5, "top: driven top must stay on border (freeze)", 0, 0, t, b)
		check(&fail, b <= PH + 0.5, "top: pinned bottom must not overflow", 0, 0, t, b)
	}

	// --- Case 2: TOP handle resumes once back inside.
	{
		c := mk_probe_clip()
		_, _, t0, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 1, PW / 2, t0, false)
		update_handle_drag(&c, canvas, PW / 2, -50, false) // freeze regime
		update_handle_drag(&c, canvas, PW / 2, PH / 2, false) // inside: resume
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, abs(t - PH/2) <= 4, "top: driven top should track pointer after resume", 0, 0, t, b)
		check(&fail, abs(b - PH) <= 0.5, "top: pinned bottom stays at canvas bottom", 0, 0, t, b)
	}

	// --- Case 3: BOTTOM handle (5), bottom edge snapped at PH. Cursor pushed
	// BELOW the canvas bottom. Frozen.
	{
		c := mk_probe_clip()
		_, _, _, b0 := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 5, PW / 2, b0, false)
		update_handle_drag(&c, canvas, PW / 2, 9999, false) // beyond bottom
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, b <= PH + 0.5, "bottom: driven bottom must stay on border (freeze)", 0, 0, t, b)
		check(&fail, t >= -0.5, "bottom: pinned top must not overflow", 0, 0, t, b)
	}

	// --- Case 4: BOTTOM handle resumes once back inside.
	{
		c := mk_probe_clip()
		_, _, _, b0 := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 5, PW / 2, b0, false)
		update_handle_drag(&c, canvas, PW / 2, PH + 40, false) // freeze regime
		update_handle_drag(&c, canvas, PW / 2, PH / 2, false) // inside: resume
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, abs(b - PH/2) <= 0.5, "bottom: driven bottom should track pointer after resume", 0, 0, t, b)
		check(&fail, abs(t - 0) <= 0.5, "bottom: pinned top stays at canvas top", 0, 0, t, b)
	}

	// --- Case 5: RIGHT handle (3), right edge snapped at PW. Cursor pushed past
	// the canvas right. Frozen.
	{
		c := mk_probe_clip()
		_, r0, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 3, r0, PH / 2, false)
		update_handle_drag(&c, canvas, 9999, PH / 2, false)
		l, r, _, _ := probe_visible_edges(&c)
		check(&fail, r <= PW + 0.5, "right: driven right must stay on border (freeze)", l, r, 0, 0)
		check(&fail, l >= -0.5, "right: pinned left must not overflow", l, r, 0, 0)
	}

	// --- Case 6: RIGHT handle resumes once back inside.
	{
		c := mk_probe_clip()
		_, r0, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 3, r0, PH / 2, false)
		update_handle_drag(&c, canvas, PW + 40, PH / 2, false) // freeze regime
		update_handle_drag(&c, canvas, PW / 2, PH / 2, false) // inside: resume
		l, r, _, _ := probe_visible_edges(&c)
		check(&fail, abs(r - PW/2) <= 0.5, "right: driven right should track pointer after resume", l, r, 0, 0)
		check(&fail, abs(l - 0) <= 0.5, "right: pinned left stays at canvas left", l, r, 0, 0)
	}

	// --- Case 7: LEFT handle (7), left edge snapped at 0. Cursor pushed past the
	// canvas left. Frozen.
	{
		c := mk_probe_clip()
		l0, _, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 7, l0, PH / 2, false)
		update_handle_drag(&c, canvas, -9999, PH / 2, false)
		l, r, _, _ := probe_visible_edges(&c)
		check(&fail, l >= -0.5, "left: driven left must stay on border (freeze)", l, r, 0, 0)
		check(&fail, r <= PW + 0.5, "left: pinned right must not overflow", l, r, 0, 0)
	}

	// --- Case 8: LEFT handle resumes once back inside.
	{
		c := mk_probe_clip()
		l0, _, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 7, l0, PH / 2, false)
		update_handle_drag(&c, canvas, -40, PH / 2, false) // freeze regime
		update_handle_drag(&c, canvas, PW / 2, PH / 2, false) // inside: resume
		l, r, _, _ := probe_visible_edges(&c)
		check(&fail, abs(l - PW/2) <= 0.5, "left: driven left should track pointer after resume", l, r, 0, 0)
		check(&fail, abs(r - PW) <= 0.5, "left: pinned right stays at canvas right", l, r, 0, 0)
	}

	if !fail {
		fmt.println("[transform-probe] OK: snap freeze holds on the border, resumes past threshold")
		os.exit(0)
	}
	os.exit(1)
}