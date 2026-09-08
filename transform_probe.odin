package main

// NERED_TRANSFORM_PROBE — regression check for preview handle scaling.
// Rules under test:
//   • a scale drag follows the pointer with NO canvas clamp — the driven edge
//     (and a whole box) may scale beyond the rendered preview space;
//   • the pinned (opposite) edge is the drag anchor and NEVER moves — not from
//     the drag, and not from a snap;
//   • only the ACTIVE handle snaps: an edge handle snaps its single driven edge
//     onto the canvas border (by adjusting scale, so the pinned edge stays
//     put); a corner snaps BOTH driven edges flush on the canvas corner.
//
// Each case builds a full-canvas box, grabs the handle ON its border, then
// asserts the pointer/border behavior. pixel<->project is identity here.

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

	// --- Case 1: TOP handle (1) scales BEYOND the border, pinned bottom stays.
	{
		c := mk_probe_clip() // full-canvas box: t=0, b=PH
		_, _, t0, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 1, PW / 2, t0, false)
		update_handle_drag(&c, canvas, PW / 2, -2000, false) // way above the canvas
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, abs(t - (-2000)) <= 0.5, "top: driven top must follow the pointer beyond the canvas", 0, 0, t, b)
		check(&fail, abs(b - PH) <= 0.5, "top: pinned bottom must not move", 0, 0, t, b)
	}

	// --- Case 2: TOP handle returns inside: driven edge still tracks the pointer.
	{
		c := mk_probe_clip()
		_, _, t0, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 1, PW / 2, t0, false)
		update_handle_drag(&c, canvas, PW / 2, PH / 2, false)
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, abs(t - PH/2) <= 0.5, "top: driven top should track the pointer", 0, 0, t, b)
		check(&fail, abs(b - PH) <= 0.5, "top: pinned bottom must not move", 0, 0, t, b)
	}

	// --- Case 3: TOP handle snaps its DRIVEN edge to the border within the margin.
	{
		c := mk_probe_clip()
		_, _, t0, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 1, PW / 2, t0, false)
		update_handle_drag(&c, canvas, PW / 2, -2, false) // ~within snap margin
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, abs(t) <= 0.05, "top: driven top should snap onto the border", 0, 0, t, b)
		check(&fail, abs(b - PH) <= 0.5, "top: pinned bottom must not move", 0, 0, t, b)
	}

	// --- Case 4: BOTTOM handle (5) scales beyond, pinned top stays.
	{
		c := mk_probe_clip()
		_, _, _, b0 := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 5, PW / 2, b0, false)
		update_handle_drag(&c, canvas, PW / 2, 9999, false) // way below the canvas
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, abs(b - 9999) <= 0.5, "bottom: driven bottom must follow the pointer beyond the canvas", 0, 0, t, b)
		check(&fail, abs(t - 0) <= 0.5, "bottom: pinned top must not move", 0, 0, t, b)
	}

	// --- Case 5: BOTTOM handle returns inside: driven edge tracks the pointer.
	{
		c := mk_probe_clip()
		_, _, _, b0 := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 5, PW / 2, b0, false)
		update_handle_drag(&c, canvas, PW / 2, PH / 2, false)
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, abs(b - PH/2) <= 0.5, "bottom: driven bottom should track the pointer", 0, 0, t, b)
		check(&fail, abs(t - 0) <= 0.5, "bottom: pinned top must not move", 0, 0, t, b)
	}

	// --- Case 6: BOTTOM handle snaps its driven edge to the border.
	{
		c := mk_probe_clip()
		_, _, _, b0 := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 5, PW / 2, b0, false)
		update_handle_drag(&c, canvas, PW / 2, PH + 2, false) // ~within snap margin
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, abs(b - PH) <= 0.05, "bottom: driven bottom should snap onto the border", 0, 0, t, b)
		check(&fail, abs(t - 0) <= 0.5, "bottom: pinned top must not move", 0, 0, t, b)
	}

	// --- Case 7: LEFT handle (7) scales beyond, pinned right stays.
	{
		c := mk_probe_clip()
		l0, _, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 7, l0, PH / 2, false)
		update_handle_drag(&c, canvas, -9999, PH / 2, false) // way left of the canvas
		l, r, _, _ := probe_visible_edges(&c)
		check(&fail, abs(l - (-9999)) <= 0.5, "left: driven left must follow the pointer beyond the canvas", l, r, 0, 0)
		check(&fail, abs(r - PW) <= 0.5, "left: pinned right must not move", l, r, 0, 0)
	}

	// --- Case 8: LEFT handle returns inside: driven edge tracks the pointer.
	{
		c := mk_probe_clip()
		l0, _, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 7, l0, PH / 2, false)
		update_handle_drag(&c, canvas, PW / 2, PH / 2, false)
		l, r, _, _ := probe_visible_edges(&c)
		check(&fail, abs(l - PW/2) <= 0.5, "left: driven left should track the pointer", l, r, 0, 0)
		check(&fail, abs(r - PW) <= 0.5, "left: pinned right must not move", l, r, 0, 0)
	}

	// --- Case 9: LEFT handle snaps its driven edge to the border.
	{
		c := mk_probe_clip()
		l0, _, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 7, l0, PH / 2, false)
		update_handle_drag(&c, canvas, -2, PH / 2, false) // ~within snap margin
		l, r, _, _ := probe_visible_edges(&c)
		check(&fail, abs(l - 0) <= 0.05, "left: driven left should snap onto the border", l, r, 0, 0)
		check(&fail, abs(r - PW) <= 0.5, "left: pinned right must not move", l, r, 0, 0)
	}

	// --- Case 10: RIGHT handle (3) scales beyond, pinned left stays.
	{
		c := mk_probe_clip()
		_, r0, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 3, r0, PH / 2, false)
		update_handle_drag(&c, canvas, 9999, PH / 2, false) // way right of the canvas
		l, r, _, _ := probe_visible_edges(&c)
		check(&fail, abs(r - 9999) <= 0.5, "right: driven right must follow the pointer beyond the canvas", l, r, 0, 0)
		check(&fail, abs(l - 0) <= 0.5, "right: pinned left must not move", l, r, 0, 0)
	}

	// --- Case 11: RIGHT handle returns inside: driven edge tracks the pointer.
	{
		c := mk_probe_clip()
		_, r0, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 3, r0, PH / 2, false)
		update_handle_drag(&c, canvas, PW / 2, PH / 2, false)
		l, r, _, _ := probe_visible_edges(&c)
		check(&fail, abs(r - PW/2) <= 0.5, "right: driven right should track the pointer", l, r, 0, 0)
		check(&fail, abs(l - 0) <= 0.5, "right: pinned left must not move", l, r, 0, 0)
	}

	// --- Case 12: RIGHT handle snaps its driven edge to the border.
	{
		c := mk_probe_clip()
		_, r0, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 3, r0, PH / 2, false)
		update_handle_drag(&c, canvas, PW + 2, PH / 2, false) // ~within snap margin
		l, r, _, _ := probe_visible_edges(&c)
		check(&fail, abs(r - PW) <= 0.05, "right: driven right should snap onto the border", l, r, 0, 0)
		check(&fail, abs(l - 0) <= 0.5, "right: pinned left must not move", l, r, 0, 0)
	}

	// --- Case 13: TL corner (0) driven far out: box scales beyond the canvas,
	// the pinned BR corner never moves.
	{
		c := mk_probe_clip()
		l0, r0, t0, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 0, l0, t0, false)
		update_handle_drag(&c, canvas, -200, -200, false)
		l, r, t, b := probe_visible_edges(&c)
		check(&fail, l < -0.5 && t < -0.5, "tl corner: driven corner must scale beyond the canvas", l, r, t, b)
		check(&fail, abs(r - PW) <= 0.5 && abs(b - PH) <= 0.5, "tl corner: pinned BR must not move", l, r, t, b)
	}

	// --- Case 14: TL corner mostly-vertical drag: dominant axis is vertical, so
	// the top edge lands EXACTLY at the pointer while the perpendicular sweep lags.
	{
		c := mk_probe_clip()
		l0, r0, t0, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 0, l0, t0, false)
		update_handle_drag(&c, canvas, 10, -600, false) // 10px on x, ~55% on y
		l, r, t, b := probe_visible_edges(&c)
		check(&fail, abs(t - (-600)) <= 0.5, "tl corner: vertical-dominant drag must scale the driven top to the pointer", l, r, t, b)
		check(&fail, abs(r - PW) <= 0.5 && abs(b - PH) <= 0.5, "tl corner: pinned BR must not move", l, r, t, b)
	}

	// --- Case 15: TL corner both driven edges snap flush on the canvas corner.
	{
		c := mk_probe_clip()
		l0, r0, t0, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, 0, l0, t0, false)
		update_handle_drag(&c, canvas, -2, -2, false) // both driven edges within snap margin
		l, r, t, b := probe_visible_edges(&c)
		check(&fail, abs(l - 0) <= 0.25 && abs(t - 0) <= 0.25, "tl corner: both driven edges must snap flush on the canvas corner", l, r, t, b)
		// The flush is closed by a small rigid translate of the box (aspect-locked
		// scaling alone can't land both edges at once), so the pinned corner rides
		// along by at most the snap margin -- it is NOT snapped to anything.
		check(&fail, abs(r - PW) <= 6 && abs(b - PH) <= 6, "tl corner: pinned BR only rides the corner flush (bounded translate)", l, r, t, b)
	}

	if !fail {
		fmt.println("[transform-probe] OK: driven edge tracks the pointer, snaps only the active handle, pinned edge holds")
		os.exit(0)
	}
	os.exit(1)
}