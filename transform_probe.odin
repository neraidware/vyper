package main

// VYPER_TRANSFORM_PROBE — regression check for preview handle scaling.
// Rules under test:
//   • a scale drag follows the pointer with NO canvas clamp — the driven edge
//     (and a whole box) may scale beyond the rendered preview space;
//   • the pinned (opposite) edge is the drag anchor and NEVER moves — not from
//     the drag, and not from a snap;
//   • only the ACTIVE handle snaps: an edge handle snaps its single driven edge
//     onto the canvas border (by adjusting scale, so the pinned edge stays
//     put); a corner snaps with an EXACT scale about the pinned corner so the
//     driven corner lands flush on the canvas corner, then FREEZES while the
//     pointer sits DIAGONALLY beyond that corner (both axes; it does not keep
//     resizing from the opposite corner) and resumes once the pointer crosses
//     back inside on either axis.
//
// Each case builds a full-canvas box, grabs the handle ON its border, then
// asserts the pointer/border behavior. pixel<->project is identity here.

import "core:c"
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
	// preview_view -> clamp_preview_camera reads clay element bounding boxes, so
	// clay must be initialized before this math runs. With no layout built it
	// returns the not-found default and the clamp falls back to the canvas size.
	// (main.odin dispatches probes before its own clay.Initialize.)
	memory := make([^]u8, clay.MinMemorySize())
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(c.size_t(clay.MinMemorySize()), memory),
		{WINDOW_WIDTH, WINDOW_HEIGHT},
		{handler = clay_probe_error},
	)

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
		begin_handle_drag(&c, canvas, .T, PW / 2, t0, false)
		update_handle_drag(&c, canvas, PW / 2, -2000, false) // way above the canvas
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, abs(t - (-2000)) <= 0.5, "top: driven top must follow the pointer beyond the canvas", 0, 0, t, b)
		check(&fail, abs(b - PH) <= 0.5, "top: pinned bottom must not move", 0, 0, t, b)
	}

	// --- Case 2: TOP handle returns inside: driven edge still tracks the pointer.
	{
		c := mk_probe_clip()
		_, _, t0, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .T, PW / 2, t0, false)
		update_handle_drag(&c, canvas, PW / 2, PH / 2, false)
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, abs(t - PH/2) <= 0.5, "top: driven top should track the pointer", 0, 0, t, b)
		check(&fail, abs(b - PH) <= 0.5, "top: pinned bottom must not move", 0, 0, t, b)
	}

	// --- Case 3: TOP handle snaps its DRIVEN edge to the border within the margin.
	{
		c := mk_probe_clip()
		_, _, t0, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .T, PW / 2, t0, false)
		update_handle_drag(&c, canvas, PW / 2, -2, false) // ~within snap margin
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, abs(t) <= 0.05, "top: driven top should snap onto the border", 0, 0, t, b)
		check(&fail, abs(b - PH) <= 0.5, "top: pinned bottom must not move", 0, 0, t, b)
	}

	// --- Case 4: BOTTOM handle (5) scales beyond, pinned top stays.
	{
		c := mk_probe_clip()
		_, _, _, b0 := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .B, PW / 2, b0, false)
		update_handle_drag(&c, canvas, PW / 2, 9999, false) // way below the canvas
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, abs(b - 9999) <= 0.5, "bottom: driven bottom must follow the pointer beyond the canvas", 0, 0, t, b)
		check(&fail, abs(t - 0) <= 0.5, "bottom: pinned top must not move", 0, 0, t, b)
	}

	// --- Case 5: BOTTOM handle returns inside: driven edge tracks the pointer.
	{
		c := mk_probe_clip()
		_, _, _, b0 := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .B, PW / 2, b0, false)
		update_handle_drag(&c, canvas, PW / 2, PH / 2, false)
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, abs(b - PH/2) <= 0.5, "bottom: driven bottom should track the pointer", 0, 0, t, b)
		check(&fail, abs(t - 0) <= 0.5, "bottom: pinned top must not move", 0, 0, t, b)
	}

	// --- Case 6: BOTTOM handle snaps its driven edge to the border.
	{
		c := mk_probe_clip()
		_, _, _, b0 := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .B, PW / 2, b0, false)
		update_handle_drag(&c, canvas, PW / 2, PH + 2, false) // ~within snap margin
		_, _, t, b := probe_visible_edges(&c)
		check(&fail, abs(b - PH) <= 0.05, "bottom: driven bottom should snap onto the border", 0, 0, t, b)
		check(&fail, abs(t - 0) <= 0.5, "bottom: pinned top must not move", 0, 0, t, b)
	}

	// --- Case 7: LEFT handle (7) scales beyond, pinned right stays.
	{
		c := mk_probe_clip()
		l0, _, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .L, l0, PH / 2, false)
		update_handle_drag(&c, canvas, -9999, PH / 2, false) // way left of the canvas
		l, r, _, _ := probe_visible_edges(&c)
		check(&fail, abs(l - (-9999)) <= 0.5, "left: driven left must follow the pointer beyond the canvas", l, r, 0, 0)
		check(&fail, abs(r - PW) <= 0.5, "left: pinned right must not move", l, r, 0, 0)
	}

	// --- Case 8: LEFT handle returns inside: driven edge tracks the pointer.
	{
		c := mk_probe_clip()
		l0, _, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .L, l0, PH / 2, false)
		update_handle_drag(&c, canvas, PW / 2, PH / 2, false)
		l, r, _, _ := probe_visible_edges(&c)
		check(&fail, abs(l - PW/2) <= 0.5, "left: driven left should track the pointer", l, r, 0, 0)
		check(&fail, abs(r - PW) <= 0.5, "left: pinned right must not move", l, r, 0, 0)
	}

	// --- Case 9: LEFT handle snaps its driven edge to the border.
	{
		c := mk_probe_clip()
		l0, _, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .L, l0, PH / 2, false)
		update_handle_drag(&c, canvas, -2, PH / 2, false) // ~within snap margin
		l, r, _, _ := probe_visible_edges(&c)
		check(&fail, abs(l - 0) <= 0.05, "left: driven left should snap onto the border", l, r, 0, 0)
		check(&fail, abs(r - PW) <= 0.5, "left: pinned right must not move", l, r, 0, 0)
	}

	// --- Case 10: RIGHT handle (3) scales beyond, pinned left stays.
	{
		c := mk_probe_clip()
		_, r0, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .R, r0, PH / 2, false)
		update_handle_drag(&c, canvas, 9999, PH / 2, false) // way right of the canvas
		l, r, _, _ := probe_visible_edges(&c)
		check(&fail, abs(r - 9999) <= 0.5, "right: driven right must follow the pointer beyond the canvas", l, r, 0, 0)
		check(&fail, abs(l - 0) <= 0.5, "right: pinned left must not move", l, r, 0, 0)
	}

	// --- Case 11: RIGHT handle returns inside: driven edge tracks the pointer.
	{
		c := mk_probe_clip()
		_, r0, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .R, r0, PH / 2, false)
		update_handle_drag(&c, canvas, PW / 2, PH / 2, false)
		l, r, _, _ := probe_visible_edges(&c)
		check(&fail, abs(r - PW/2) <= 0.5, "right: driven right should track the pointer", l, r, 0, 0)
		check(&fail, abs(l - 0) <= 0.5, "right: pinned left must not move", l, r, 0, 0)
	}

	// --- Case 12: RIGHT handle snaps its driven edge to the border.
	{
		c := mk_probe_clip()
		_, r0, _, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .R, r0, PH / 2, false)
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
		begin_handle_drag(&c, canvas, .TL, l0, t0, false)
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
		begin_handle_drag(&c, canvas, .TL, l0, t0, false)
		update_handle_drag(&c, canvas, 10, -600, false) // 10px on x, ~55% on y
		l, r, t, b := probe_visible_edges(&c)
		check(&fail, abs(t - (-600)) <= 0.5, "tl corner: vertical-dominant drag must scale the driven top to the pointer", l, r, t, b)
		check(&fail, abs(r - PW) <= 0.5 && abs(b - PH) <= 0.5, "tl corner: pinned BR must not move", l, r, t, b)
	}

	// --- Case 15: TL corner both driven edges snap flush on the canvas corner.
	{
		c := mk_probe_clip()
		l0, r0, t0, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .TL, l0, t0, false)
		update_handle_drag(&c, canvas, -2, -2, false) // both driven edges within snap margin
		l, r, t, b := probe_visible_edges(&c)
		check(&fail, abs(l - 0) <= 0.25 && abs(t - 0) <= 0.25, "tl corner: both driven edges must snap flush on the canvas corner", l, r, t, b)
		// The flush is now scale-exact about the pinned corner (aspect-matched
		// box), so the pinned BR does NOT ride along: it stays put.
		check(&fail, abs(r - PW) <= 0.5 && abs(b - PH) <= 0.5, "tl corner: pinned BR must not move on a scale-exact snap", l, r, t, b)
	}

	// --- Case 16: TL corner snapped flush, pointer pushed BEYOND the corner:
	// the box FREEZES at its snapped geometry instead of resizing from the
	// opposite (pinned) corner.
	{
		c := mk_probe_clip()
		l0, r0, t0, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .TL, l0, t0, false)
		update_handle_drag(&c, canvas, -2, -2, false) // snap flush on (0,0)
		s_snapped := c.scale
		_, r_snapped, _, b_snapped := probe_visible_edges(&c)
		update_handle_drag(&c, canvas, -400, -400, false) // well beyond the corner
		l, r, t, b := probe_visible_edges(&c)
		check(&fail, abs(l - 0) <= 0.25 && abs(t - 0) <= 0.25, "tl freeze: driven corner must stay flush while the pointer is beyond it", l, r, t, b)
		check(&fail, abs(r - r_snapped) <= 0.5 && abs(b - b_snapped) <= 0.5, "tl freeze: pinned corner must not move while frozen", l, r, t, b)
		check(&fail, abs(c.scale - s_snapped) <= 0.01, "tl freeze: scale must hold while frozen", l, r, t, b)
	}

	// --- Case 17: TL corner frozen, pointer crosses back inside the margin:
	// resize resumes (the box re-detaches and the driven corner tracks again).
	{
		c := mk_probe_clip()
		l0, r0, t0, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .TL, l0, t0, false)
		update_handle_drag(&c, canvas, -2, -2, false) // snap flush
		update_handle_drag(&c, canvas, -200, -200, false) // freeze
		update_handle_drag(&c, canvas, -2, -2, false) // back inside the snap margin
		l, r, t, b := probe_visible_edges(&c)
		check(&fail, abs(l - 0) <= 0.25 && abs(t - 0) <= 0.25, "tl resume: corner re-snaps flush once the pointer is inside again", l, r, t, b)
		update_handle_drag(&c, canvas, PW / 2, PH / 2, false) // well inside the canvas
		l, r, t, b = probe_visible_edges(&c)
		check(&fail, abs(l - PW/2) <= 0.5 && abs(t - PH/2) <= 0.5, "tl resume: driven corner tracks the pointer again after un-freeze", l, r, t, b)
	}

	// --- Case 18: TL corner snap is scale-exact: a full-canvas 16:9 box dragged
	// to (-2,-2) must end at EXACTLY canvas size (scale 1.0), corner flush on
	// (0,0), pinned BR unmoved. (The old rigid-translate snap left the scale
	// ballistic and shifted BR out of the canvas.)
	{
		c := mk_probe_clip()
		l0, r0, t0, _ := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .TL, l0, t0, false)
		update_handle_drag(&c, canvas, -2, -2, false)
		l, r, t, b := probe_visible_edges(&c)
		check(&fail, abs(c.scale - 1.0) <= 0.01, "tl corner: snapped scale must be the exact flush scale (1.0)", l, r, t, b)
		check(&fail, abs(l - 0) <= 0.25 && abs(t - 0) <= 0.25, "tl corner: corner flush", l, r, t, b)
		check(&fail, abs(r - PW) <= 0.5 && abs(b - PH) <= 0.5, "tl corner: pinned BR exactly on its corner", l, r, t, b)
	}

	// --- Case 19: BR corner snap-freeze-resume (mirror of 16/17 for .BR).
	{
		c := mk_probe_clip()
		_, _, _, b0 := probe_visible_edges(&c)
		begin_handle_drag(&c, canvas, .BR, PW, b0, false)
		update_handle_drag(&c, canvas, PW - 2, PH - 2, false) // snap flush BR
		update_handle_drag(&c, canvas, PW + 400, PH + 400, false) // freeze beyond
		l, r, t, b := probe_visible_edges(&c)
		check(&fail, abs(r - PW) <= 0.25 && abs(b - PH) <= 0.25, "br freeze: driven corner stays flush while beyond", l, r, t, b)
		update_handle_drag(&c, canvas, PW - 400, PH - 300, false) // deep inside
		l, r, t, b = probe_visible_edges(&c)
		check(&fail, abs(r - PW) > 50 && abs(b - PH) > 50, "br resume: box must detach once the pointer is inside", l, r, t, b)
	}

	// --- Case 20: TR corner snap-freeze-resume.
	{
		c := mk_probe_clip()
		begin_handle_drag(&c, canvas, .TR, PW, 0, false)
		update_handle_drag(&c, canvas, PW - 2, 2, false) // snap flush TR
		update_handle_drag(&c, canvas, PW + 400, -400, false) // freeze beyond
		l, r, t, b := probe_visible_edges(&c)
		check(&fail, abs(r - PW) <= 0.25 && abs(t - 0) <= 0.25, "tr freeze: driven corner stays flush while beyond", l, r, t, b)
		update_handle_drag(&c, canvas, PW - 400, 300, false) // deep inside
		l, r, t, b = probe_visible_edges(&c)
		check(&fail, abs(r - PW) > 50 && abs(t - 0) > 50, "tr resume: box must detach once the pointer is inside", l, r, t, b)
	}

	// --- Case 21: BL corner snap-freeze-resume.
	{
		c := mk_probe_clip()
		begin_handle_drag(&c, canvas, .BL, 0, PH, false)
		update_handle_drag(&c, canvas, 2, PH - 2, false) // snap flush BL
		update_handle_drag(&c, canvas, -400, PH + 400, false) // freeze beyond
		l, r, t, b := probe_visible_edges(&c)
		check(&fail, abs(l - 0) <= 0.25 && abs(b - PH) <= 0.25, "bl freeze: driven corner stays flush while beyond", l, r, t, b)
		update_handle_drag(&c, canvas, 400, PH - 300, false) // deep inside
		l, r, t, b = probe_visible_edges(&c)
		check(&fail, abs(l - 0) > 50 && abs(b - PH) > 50, "bl resume: box must detach once the pointer is inside", l, r, t, b)
	}

	// --- Case 22: freeze requires the pointer DIAGONALLY beyond the corner
	// (both axes). Once one axis returns inside the canvas the box must detach
	// immediately -- single-axis-beyond behaves like an edge drag -- so a sweep
	// along the bottom/top edge plane never leaves the handle stuck. Only the
	// diagonal overflow freezes.
	{
		c := mk_probe_clip()
		begin_handle_drag(&c, canvas, .BR, PW, PH, false)
		update_handle_drag(&c, canvas, PW - 2, PH - 2, false) // snap flush BR
		update_handle_drag(&c, canvas, PW + 400, PH + 400, false) // diagonal beyond -> held
		l, r, t, b := probe_visible_edges(&c)
		check(&fail, abs(r - PW) <= 0.25 && abs(b - PH) <= 0.25, "br diagonal: beyond on both axes holds the flush box", l, r, t, b)
		update_handle_drag(&c, canvas, PW - 400, PH + 400, false) // x back inside, y still beyond
		l, r, t, b = probe_visible_edges(&c)
		check(&fail, abs(r - PW) > 50, "br single-axis: box detaches as soon as one axis returns inside", l, r, t, b)
		check(&fail, abs(b - PH) > 50, "br single-axis: driven corner follows the pointer again", l, r, t, b)
	}

	// --- Case 23: the fit-to-window toggle pins the camera to the contain-fit
	// even when zoom/pan were dirtied, and releasing it lets the manual camera
	// apply. This is the "always fits" invariant the toolbar toggle relies on.
	{
		preview_fit_to_window = true
		preview_cam_zoom = 4
		preview_cam_ox = 123
		preview_cam_oy = -45
		v := preview_view(canvas)
		check(
			&fail,
			abs(preview_cam_zoom - 1) <= 0.0001 &&
			abs(preview_cam_ox) <= 0.0001 &&
			abs(preview_cam_oy) <= 0.0001,
			"fit: dirty camera must snap back to zoom 1 / no pan",
			v.x,
			v.x + v.width,
			v.y,
			v.y + v.height,
		)
		check(
			&fail,
			abs(v.x - canvas.x) <= 0.0001 && abs(v.width - canvas.width) <= 0.0001,
			"fit: view must equal the base canvas",
			v.x,
			v.x + v.width,
			v.y,
			v.y + v.height,
		)
		preview_fit_to_window = false
		preview_cam_zoom = 2
		v = preview_view(canvas)
		check(
			&fail,
			abs(v.width - canvas.width * 2) <= 0.0001,
			"released: manual zoom must apply",
			v.x,
			v.x + v.width,
			v.y,
			v.y + v.height,
		)
		preview_fit_to_window = true
	}

	if !fail {
		fmt.println("[transform-probe] OK: driven edge tracks the pointer, snaps only the active handle, pinned edge holds")
		os.exit(0)
	}
	os.exit(1)
}
